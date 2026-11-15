//// The process that owns the store's tables. It grants locks, detects
//// deadlocks, applies each commit as one write, monitors every process
//// that holds a transaction (and rolls it back by dropping its locks when
//// that process dies), and tells subscribers what committed.
////
//// Its mailbox holds at most one request per process using the store:
//// every request but `Unsubscribe` and `Stop` is synchronous.

import decisions_otp/internal/rows.{type Lock, type Table}
import decisions_otp/live.{type Hint, type Topic}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

/// What one commit changed about one occurrence, for the subscribers.
pub type Change {
  Change(
    point: String,
    occurrence: String,
    status: String,
    queues: List(String),
    /// Whether a review is pending before or after the commit.
    reviews: Bool,
  )
}

/// A lock request's answer.
pub type Grant {
  Granted
  /// Waiting would close a cycle of transactions waiting for each other.
  Deadlock
  /// The request was withdrawn before it was granted.
  Withdrawn
}

pub type Message {
  Begin(pid: Pid, reply: Subject(Int))
  Acquire(tx: Int, lock: Lock, reply: Subject(Grant))
  Withdraw(tx: Int, reply: Subject(Grant))
  /// Commit `writes` when present; roll back otherwise.
  Finish(
    tx: Int,
    writes: Option(List(#(rows.Key, Option(rows.Row)))),
    changes: List(Change),
    reply: Subject(Nil),
  )
  Subscribe(
    topic: Topic,
    subscriber: Subject(Hint),
    reply: Subject(Result(Int, Nil)),
  )
  Unsubscribe(id: Int)
  Exited(process.Down)
  /// The tables and the settings `#(lock_timeout, capacity, backoff)`,
  /// for a handle taken by name.
  Describe(reply: Subject(#(Tables, #(Int, Int, Int))))
  /// Tell subscribers that missed hints, once their mailboxes have room.
  Flush
  /// Run a read between two commits, for a reader that could not find
  /// such a moment by itself. `read` sends its own answer.
  Run(read: fn() -> Nil)
  /// Copy every committed row and counter, answer with the copy, and
  /// stop, in one step: a commit that arrives after it is never applied,
  /// and its caller learns that its outcome is unknown.
  Snapshot(reply: Subject(#(List(#(rows.Key, rows.Row)), List(#(String, Int)))))
  Stop
}

/// The tables the owner creates and owns.
pub type Tables {
  Tables(rows: Table, counters: Table, claims: Table)
}

type Open {
  Open(
    pid: Pid,
    monitor: Monitor,
    held: List(Lock),
    waiting: Option(#(Lock, Subject(Grant))),
  )
}

type Subscriber {
  Subscriber(
    topic: Topic,
    subject: Subject(Hint),
    pid: Pid,
    monitor: Monitor,
    missed: Int,
  )
}

type State {
  State(
    tables: Tables,
    capacity: Int,
    next: Int,
    open: Dict(Int, Open),
    holders: Dict(Lock, Int),
    queues: Dict(Lock, List(Int)),
    subscribers: Dict(Int, Subscriber),
    by_topic: Dict(Topic, List(Int)),
    settings: #(Int, Int, Int),
    self: Subject(Message),
    /// Whether a `Flush` is on its way.
    flushing: Bool,
  )
}

/// Start the owner, linked to the caller. `load` fills the new tables
/// before the first request is served. `capacity` is how many messages a
/// subscriber's mailbox may hold before hints to it are dropped.
pub fn start(
  capacity: Int,
  name: Option(process.Name(Message)),
  settings: #(Int, Int, Int),
  load: fn(Tables) -> Nil,
) -> Result(actor.Started(#(Subject(Message), Tables)), actor.StartError) {
  let builder =
    actor.new_with_initialiser(1000, fn(self) {
      let tables =
        Tables(
          rows: rows.new_table(),
          counters: rows.new_table(),
          claims: rows.new_table(),
        )
      load(tables)
      let selector =
        process.new_selector()
        |> process.select(self)
        |> process.select_monitors(Exited)
      let state =
        State(
          tables:,
          capacity:,
          next: 1,
          open: dict.new(),
          holders: dict.new(),
          queues: dict.new(),
          subscribers: dict.new(),
          by_topic: dict.new(),
          settings:,
          self:,
          flushing: False,
        )
      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(#(self, tables))
      |> Ok
    })
    |> actor.on_message(handle)
  case name {
    Some(name) -> actor.named(builder, name)
    None -> builder
  }
  |> actor.start
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Begin(pid:, reply:) -> {
      let id = state.next
      let open =
        Open(pid:, monitor: process.monitor(pid), held: [], waiting: None)
      process.send(reply, id)
      actor.continue(
        State(..state, next: id + 1, open: dict.insert(state.open, id, open)),
      )
    }
    Acquire(tx:, lock:, reply:) ->
      actor.continue(acquire(state, tx, lock, reply))
    Withdraw(tx:, reply:) -> actor.continue(withdraw(state, tx, reply))
    Finish(tx:, writes:, changes:, reply:) -> {
      let state = case writes {
        Some(writes) -> {
          commit(state.tables, writes)
          tell(state, changes)
        }
        None -> state
      }
      let state = case dict.get(state.open, tx) {
        Ok(open) -> {
          process.demonitor_process(open.monitor)
          end(state, tx)
        }
        Error(Nil) -> state
      }
      process.send(reply, Nil)
      actor.continue(state)
    }
    Subscribe(topic:, subscriber:, reply:) ->
      case process.subject_owner(subscriber) {
        Ok(pid) -> {
          let id = state.next
          let entry =
            Subscriber(
              topic:,
              subject: subscriber,
              pid:,
              monitor: process.monitor(pid),
              missed: 0,
            )
          process.send(reply, Ok(id))
          actor.continue(
            State(
              ..state,
              next: id + 1,
              subscribers: dict.insert(state.subscribers, id, entry),
              by_topic: dict.upsert(state.by_topic, topic, fn(ids) {
                [id, ..option.unwrap(ids, [])]
              }),
            ),
          )
        }
        // A named subject without a process: nobody to tell.
        Error(Nil) -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
      }
    Unsubscribe(id:) -> actor.continue(unsubscribe(state, id))
    Exited(down) ->
      case down {
        process.ProcessDown(pid:, ..) -> actor.continue(exited(state, pid))
        process.PortDown(..) -> actor.continue(state)
      }
    Describe(reply:) -> {
      process.send(reply, #(state.tables, state.settings))
      actor.continue(state)
    }
    Flush -> actor.continue(flush(State(..state, flushing: False)))
    Run(read:) -> {
      let _ = rows.attempt(read)
      actor.continue(state)
    }
    Snapshot(reply:) -> {
      process.send(reply, #(
        rows.all_rows(state.tables.rows),
        rows.all_counters(state.tables.counters),
      ))
      actor.stop()
    }
    Stop -> actor.stop()
  }
}

/// Apply one commit so that readers see all of it or none of it: the
/// version is odd while it is applied (see `rows.stable`). The paged
/// indexes get their commit number and commit time here, so a reader that
/// pages by them never passes a row still to commit.
fn commit(tables: Tables, writes: List(#(rows.Key, Option(rows.Row)))) -> Nil {
  let odd = rows.bump_version(tables.rows)
  let number = { odd + 1 } / 2
  let at =
    int.max(
      rows.clock_ms(tables.counters),
      rows.peek(tables.counters, "commit_ms"),
    )
  rows.set(tables.counters, "commit_ms", at)
  let writes =
    list.map(writes, fn(write) {
      case write.0 {
        rows.PointKey(point:, at: #(-1, id)) -> #(
          rows.PointKey(point:, at: #(number, id)),
          write.1,
        )
        rows.SettledKey(point:, at: #(-1, -1, id)) -> #(
          rows.SettledKey(point:, at: #(at, number, id)),
          write.1,
        )
        _ -> write
      }
    })
  rows.apply_writes(tables.rows, writes)
  let _ = rows.bump_version(tables.rows)
  Nil
}

// -- Locks ---------------------------------------------------------------------

fn acquire(state: State, tx: Int, lock: Lock, reply: Subject(Grant)) -> State {
  case dict.get(state.open, tx), dict.get(state.holders, lock) {
    // A transaction the owner no longer knows: its process died.
    Error(Nil), _ -> {
      process.send(reply, Withdrawn)
      state
    }
    Ok(open), Error(Nil) -> {
      process.send(reply, Granted)
      hold(state, tx, open, lock)
    }
    Ok(_), Ok(holder) if holder == tx -> {
      process.send(reply, Granted)
      state
    }
    Ok(open), Ok(holder) ->
      case waits_for(state, holder, tx, 0) {
        True -> {
          process.send(reply, Deadlock)
          state
        }
        False ->
          State(
            ..state,
            open: dict.insert(
              state.open,
              tx,
              Open(..open, waiting: Some(#(lock, reply))),
            ),
            queues: dict.upsert(state.queues, lock, fn(queue) {
              list.append(option.unwrap(queue, []), [tx])
            }),
          )
      }
  }
}

/// Whether `holder` waits, directly or through others, for `tx`.
fn waits_for(state: State, holder: Int, tx: Int, depth: Int) -> Bool {
  case holder == tx, depth > 10_000 {
    True, _ -> True
    False, True -> True
    False, False ->
      case dict.get(state.open, holder) {
        Ok(Open(waiting: Some(#(lock, _)), ..)) ->
          case dict.get(state.holders, lock) {
            Ok(next) -> waits_for(state, next, tx, depth + 1)
            Error(Nil) -> False
          }
        _ -> False
      }
  }
}

fn hold(state: State, tx: Int, open: Open, lock: Lock) -> State {
  State(
    ..state,
    open: dict.insert(
      state.open,
      tx,
      Open(..open, held: [lock, ..open.held], waiting: None),
    ),
    holders: dict.insert(state.holders, lock, tx),
  )
}

fn withdraw(state: State, tx: Int, reply: Subject(Grant)) -> State {
  case dict.get(state.open, tx) {
    Ok(Open(waiting: Some(#(lock, _)), ..) as open) -> {
      process.send(reply, Withdrawn)
      State(
        ..state,
        open: dict.insert(state.open, tx, Open(..open, waiting: None)),
        queues: dict.upsert(state.queues, lock, fn(queue) {
          list.filter(option.unwrap(queue, []), fn(other) { other != tx })
        }),
      )
    }
    // Granted before the withdrawal arrived.
    Ok(_) -> {
      process.send(reply, Granted)
      state
    }
    Error(Nil) -> {
      process.send(reply, Withdrawn)
      state
    }
  }
}

/// Forget a transaction: release its locks to the next waiter of each,
/// and take it out of any queue it waits in.
fn end(state: State, tx: Int) -> State {
  case dict.get(state.open, tx) {
    Error(Nil) -> state
    Ok(open) -> {
      let state = State(..state, open: dict.delete(state.open, tx))
      let state = case open.waiting {
        Some(#(lock, _)) ->
          State(
            ..state,
            queues: dict.upsert(state.queues, lock, fn(queue) {
              list.filter(option.unwrap(queue, []), fn(other) { other != tx })
            }),
          )
        None -> state
      }
      list.fold(open.held, state, release)
    }
  }
}

fn release(state: State, lock: Lock) -> State {
  let state = State(..state, holders: dict.delete(state.holders, lock))
  let queue = dict.get(state.queues, lock) |> result.unwrap([])
  grant_next(state, lock, queue)
}

fn grant_next(state: State, lock: Lock, queue: List(Int)) -> State {
  case queue {
    [] -> State(..state, queues: dict.delete(state.queues, lock))
    [next, ..rest] ->
      case dict.get(state.open, next) {
        Ok(Open(waiting: Some(#(wanted, reply)), ..) as open)
          if wanted == lock
        -> {
          process.send(reply, Granted)
          let state =
            State(..state, queues: dict.insert(state.queues, lock, rest))
          hold(state, next, open, lock)
        }
        _ -> grant_next(state, lock, rest)
      }
  }
}

fn exited(state: State, pid: Pid) -> State {
  let transactions =
    dict.to_list(state.open)
    |> list.filter_map(fn(pair) {
      case { pair.1 }.pid == pid {
        True -> Ok(pair.0)
        False -> Error(Nil)
      }
    })
  let state = list.fold(transactions, state, end)
  let subscriptions =
    dict.to_list(state.subscribers)
    |> list.filter_map(fn(pair) {
      case { pair.1 }.pid == pid {
        True -> Ok(pair.0)
        False -> Error(Nil)
      }
    })
  list.fold(subscriptions, state, unsubscribe)
}

// -- Subscribers -------------------------------------------------------------------

fn unsubscribe(state: State, id: Int) -> State {
  case dict.get(state.subscribers, id) {
    Error(Nil) -> state
    Ok(subscriber) -> {
      process.demonitor_process(subscriber.monitor)
      State(
        ..state,
        subscribers: dict.delete(state.subscribers, id),
        by_topic: dict.upsert(state.by_topic, subscriber.topic, fn(ids) {
          list.filter(option.unwrap(ids, []), fn(other) { other != id })
        }),
      )
    }
  }
}

fn tell(state: State, changes: List(Change)) -> State {
  case dict.is_empty(state.subscribers) {
    True -> state
    False -> list.fold(changes, state, tell_one)
  }
}

fn tell_one(state: State, change: Change) -> State {
  let topics = [
    live.ToOccurrence(change.occurrence),
    live.ToPoint(change.point),
    ..list.map(change.queues, live.ToQueue)
  ]
  let topics = case change.reviews {
    True -> [live.ToReviews(change.point), ..topics]
    False -> topics
  }
  let ids =
    list.flat_map(topics, fn(topic) {
      dict.get(state.by_topic, topic) |> result.unwrap([])
    })
    |> list.unique
  let hint =
    live.Changed(
      point: change.point,
      occurrence: change.occurrence,
      status: change.status,
    )
  let subscribers =
    list.fold(ids, state.subscribers, fn(subscribers, id) {
      case dict.get(subscribers, id) {
        Error(Nil) -> subscribers
        Ok(subscriber) ->
          dict.insert(
            subscribers,
            id,
            send_hint(subscriber, hint, state.capacity),
          )
      }
    })
  State(..state, subscribers:) |> keep_flushing
}

/// While any subscriber has missed hints, look again in 20 ms.
fn keep_flushing(state: State) -> State {
  let behind =
    dict.values(state.subscribers) |> list.any(fn(s) { s.missed > 0 })
  case behind, state.flushing {
    True, False -> {
      process.send_after(state.self, 20, Flush)
      State(..state, flushing: True)
    }
    _, _ -> state
  }
}

/// Tell each subscriber that missed hints how many, as soon as its
/// mailbox has room, even when nothing changes after.
fn flush(state: State) -> State {
  let subscribers =
    dict.map_values(state.subscribers, fn(_, subscriber) {
      case subscriber.missed > 0 && mailbox(subscriber.pid) < state.capacity {
        True -> {
          process.send(subscriber.subject, live.Missed(subscriber.missed))
          Subscriber(..subscriber, missed: 0)
        }
        False -> subscriber
      }
    })
  State(..state, subscribers:) |> keep_flushing
}

/// A subscriber whose mailbox is full is not sent the hint; it is told how
/// many it missed with the next one that fits.
fn send_hint(subscriber: Subscriber, hint: Hint, capacity: Int) -> Subscriber {
  case mailbox(subscriber.pid) >= capacity {
    True -> Subscriber(..subscriber, missed: subscriber.missed + 1)
    False -> {
      case subscriber.missed {
        0 -> Nil
        count -> process.send(subscriber.subject, live.Missed(count))
      }
      process.send(subscriber.subject, hint)
      Subscriber(..subscriber, missed: 0)
    }
  }
}

@external(erlang, "decisions_otp_ffi", "mailbox")
fn mailbox(pid: Pid) -> Int
