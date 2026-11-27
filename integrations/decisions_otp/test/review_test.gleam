//// The corrections an independent review of the package asked for, one
//// test each (O1 to O7).

import decisions
import decisions/model
import decisions/store as port_types
import decisions/vocabulary.{
  Manifest, Person, Recommendation, RuleFired, Rules, Subject,
}
import decisions/wire
import decisions_otp/backlog
import decisions_otp/isolated
import decisions_otp/live
import decisions_otp/replay
import decisions_otp/runtime
import decisions_otp/store
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/time/duration
import support/lab

fn head(
  point: String,
  status: port_types.Status,
  awaiting: List(String),
  due_ms: option.Option(Int),
) -> port_types.Head {
  port_types.Head(
    point:,
    subject: Subject("person", "x"),
    status:,
    awaiting:,
    due: option.map(due_ms, wire.from_milliseconds),
    arrived: wire.from_milliseconds(1),
    approved: [],
    may_not_decide: [],
    review_pending: False,
    bundle: None,
  )
}

fn entry(seq: Int, kind: String) -> port_types.Stored {
  port_types.Stored(seq:, at: wire.from_milliseconds(seq), kind:, event: "{}")
}

/// O1. A restart keeps every commit it acknowledged, with commits in
/// flight from eight processes.
pub fn a_restart_keeps_every_acknowledged_commit_test() {
  list.each(lab.numbers(1, 5), fn(_) {
    let s = lab.start()
    let acked = process.new_subject()
    let writers =
      list.map(lab.numbers(1, 8), fn(n) {
        process.spawn_unlinked(fn() { write_forever(s, n, 0, acked) })
      })
    // Restart once a commit has been acknowledged: commits are in flight.
    let assert Ok(first) = process.receive(acked, 10_000)
    let assert Ok(again) = store.restart(s, lab.config())
    list.each(writers, lab.kill)
    let acknowledged = drain(acked, [first])
    let kept =
      lab.within(again, store.rows(_, "acked"))
      |> list.map(fn(pair) { pair.1 })
      |> set.from_list
    assert acknowledged != []
    assert list.all(acknowledged, set.contains(kept, _))
  })
}

fn write_forever(
  s: store.Store,
  writer: Int,
  n: Int,
  acked: process.Subject(String),
) -> Nil {
  let key = int.to_string(writer) <> "-" <> int.to_string(n)
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) {
      store.add(tx, "acked", key)
      Ok(Nil)
    })
  process.send(acked, key)
  write_forever(s, writer, n + 1, acked)
}

fn drain(subject: process.Subject(a), so_far: List(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(value) -> drain(subject, [value, ..so_far])
    Error(Nil) -> so_far
  }
}

/// O2. A reader never sees a commit in part: a card whose due time moves
/// in every commit is never in its queue twice, nor missing.
pub fn a_reader_never_sees_a_commit_in_part_test() {
  let s = lab.start()
  let port = store.port()
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) {
      port.append(
        tx,
        "occ-x",
        head("p", port_types.Awaiting, ["s"], Some(1000)),
        [
          entry(1, "recommended"),
        ],
      )
    })
  let done = process.new_subject()
  process.spawn(fn() {
    list.each(lab.numbers(2, 3001), fn(seq) {
      let assert Ok(Nil) =
        store.transaction(s, fn(tx) {
          let assert Ok(_) = port.load(tx, "occ-x")
          port.append(
            tx,
            "occ-x",
            head("p", port_types.Awaiting, ["s"], Some(1000 + seq)),
            [entry(seq, "noted")],
          )
        })
    })
    process.send(done, Nil)
  })
  let bad = read_until_done(s, done, 0, 0)
  // The reader overlapped the writer (it read before the writer was done)
  // and never saw the card twice or missing.
  assert bad.0 >= 2
  assert bad.1 == 0
}

fn read_until_done(
  s: store.Store,
  done: process.Subject(Nil),
  reads: Int,
  wrong: Int,
) -> #(Int, Int) {
  let seen = store.queue(s, "s")
  let wrong = case seen {
    ["occ-x"] -> wrong
    _ -> wrong + 1
  }
  case process.receive(done, 0) {
    Ok(Nil) -> #(reads + 1, wrong)
    Error(Nil) -> read_until_done(s, done, reads + 1, wrong)
  }
}

/// O3. A settlement that commits after a later-stamped one is still read
/// once by a reader that keeps its cursor; the same for `occurrences_of`.
pub fn a_page_reader_does_not_skip_a_late_commit_test() {
  let s = lab.start()
  let port = store.port()
  let holding = process.new_subject()
  let go = process.new_subject()
  // A settles first on the clock, but commits last.
  let first =
    process.spawn(fn() {
      let gate = process.new_subject()
      process.send(go, gate)
      let assert Ok(Nil) =
        store.transaction(s, fn(tx) {
          let assert Ok(Nil) =
            port.append(tx, "a", head("q", port_types.Released, [], None), [
              entry(1, "recommended"),
            ])
          process.send(holding, Nil)
          let assert Ok(Nil) = process.receive(gate, 5000)
          Ok(Nil)
        })
    })
  let assert Ok(gate) = process.receive(go, 1000)
  let assert Ok(Nil) = process.receive(holding, 1000)
  let since = wire.from_milliseconds(0)
  store.advance(s, duration.seconds(1))
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) {
      port.append(tx, "b", head("q", port_types.Released, [], None), [
        entry(1, "recommended"),
      ])
    })
  let page = store.settled_since(s, "q", since:, after: None, limit: 10)
  let points = store.occurrences_of(s, "q", after: None, limit: 10)
  assert page.ids == ["b"]
  assert points.ids == ["b"]
  process.send(gate, Nil)
  let monitor = process.monitor(first)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  let cursor =
    last_cursor(fn(after) {
      store.settled_since(s, "q", since:, after:, limit: 1)
    })
  let next = store.settled_since(s, "q", since:, after: cursor, limit: 10)
  assert next.ids == ["a"]
  let point_cursor =
    last_cursor(fn(after) { store.occurrences_of(s, "q", after:, limit: 1) })
  assert point_cursor != None
  let all = store.occurrences_of(s, "q", after: None, limit: 10)
  assert all.ids == ["b", "a"]
}

/// The cursor after the first page of one.
fn last_cursor(
  read: fn(option.Option(store.Cursor)) -> store.Page,
) -> option.Option(store.Cursor) {
  case read(None) {
    store.Page(ids: [_], next: next) ->
      case next {
        Some(_) -> next
        // A page that is the last one: page again past it.
        None -> None
      }
    _ -> None
  }
}

/// O4. Wake-ups the store cannot take (contended for ever) do not block a
/// healthy one behind them in the same batch.
pub fn a_stuck_job_does_not_block_the_jobs_behind_it_test() {
  let s = lab.start()
  let port = store.port()
  let stuck =
    decisions.desk(
      lab.point("stuck", None),
      drives: fn(_) {
        decisions.Gated(
          name: "none",
          guard: fn(_, _) { Ok([]) },
          execute: fn(_, _) { Ok(Nil) },
        )
      },
      under: fn(_) { Ok(lab.proceeding()) },
      over: port_types.Port(..port, load: fn(_, _) {
        Error(port_types.Contended("busy for ever"))
      }),
    )
  let healthy =
    lab.desk(lab.point("healthy", Some(duration.minutes(1))), lab.proceeding())
  let assert Ok(_) =
    store.transaction(s, lab.recommend(
      healthy,
      _,
      "h-1",
      about: lab.ana,
      output: "Olá",
      by: Person("bia"),
      score: 1.0,
    ))
  // Two stuck wake-ups due before the healthy one.
  let assert Ok(Nil) =
    store.transaction(
      s,
      port.schedule(_, "stuck", "s-1", [wire.from_milliseconds(1)]),
    )
  let assert Ok(Nil) =
    store.transaction(
      s,
      port.schedule(_, "stuck", "s-2", [wire.from_milliseconds(2)]),
    )
  store.advance(s, duration.minutes(2))
  let tree =
    lab.start_runtime(
      runtime.Config(
        ..runtime.config(
          store.backlog(s),
          points: [
            runtime.point(stuck, settled: runtime.nothing_follows),
            runtime.point(healthy, settled: runtime.nothing_follows),
          ],
          work: fn(_) { Ok(Nil) },
        ),
        batch: 2,
        poll: duration.milliseconds(20),
      ),
    )
  let ok = lab.wait_until(fn() { lab.effects(s, healthy) == 1 }, within: 3000)
  lab.stop_runtime(tree)
  assert ok
  // The stuck ones were never counted.
  assert store.backlog(s).aside() == Ok([])
}

/// O5. More than 256 triggers backing off do not hide a new one.
pub fn triggers_backing_off_do_not_hide_a_new_one_test() {
  lab.quiet()
  let assert Ok(s) =
    store.start(
      store.Config(..store.defaults(), retry_backoff: duration.hours(1)),
    )
  let jobs = store.backlog(s)
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) {
      list.try_each(lab.numbers(1, 300), fn(n) {
        jobs.submit(tx, "old-" <> int.to_string(n), "")
      })
    })
  // Claim each and count a failure: each backs off for an hour.
  list.each(lab.numbers(1, 300), fn(_) {
    let assert Ok(Some(submitted)) = jobs.claim_trigger()
    let assert Ok(1) =
      store.transaction(s, fn(tx) {
        jobs.failed(tx, backlog.TriggerJob(submitted), "failed")
      })
    jobs.release(submitted)
  })
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) { jobs.submit(tx, "new", "") })
  let assert Ok(Some(found)) = jobs.claim_trigger()
  assert found.key == "new"
}

/// O6. A page of a validator's queue is the head of their whole queue.
pub fn a_validator_s_page_is_the_head_of_their_queue_test() {
  let s = lab.start()
  let finance = lab.desk(lab.point("o6.finance", None), lab.asking("finance"))
  let support = lab.desk(lab.point("o6.support", None), lab.asking("support"))
  list.each(lab.numbers(1, 60), fn(n) {
    let desk = case n % 2 {
      0 -> finance
      _ -> support
    }
    let assert Ok(_) =
      store.transaction(s, lab.recommend(
        desk,
        _,
        "o6-" <> int.to_string(n),
        about: lab.ana,
        output: "x",
        by: Rules("rules", "1"),
        score: 0.5,
      ))
    store.advance(s, duration.milliseconds(1))
  })
  let everything = store.queue_for(s, lab.bia)
  assert list.length(everything) == 60
  assert store.queue_page_for(s, lab.bia, 7) == list.take(everything, 7)
  assert store.queue_page_for(s, lab.bia, 100) == everything
}

/// O7. A wake-up still backing off is not taken by a second runtime.
pub fn a_wake_up_backing_off_is_not_taken_test() {
  lab.quiet()
  let assert Ok(s) =
    store.start(
      store.Config(..store.defaults(), retry_backoff: duration.hours(1)),
    )
  let jobs = store.backlog(s)
  let wake = port_types.Wake("p", "o-1", wire.from_milliseconds(1))
  let assert Ok(Nil) =
    store.transaction(s, store.port().schedule(_, "p", "o-1", [wake.at]))
  let assert Ok(1) =
    store.transaction(s, fn(tx) { jobs.failed(tx, backlog.WakeJob(wake), "x") })
  assert store.transaction(s, fn(tx) { jobs.take_wake(tx, wake) }) == Ok(False)
  assert jobs.due(store.now(s), 10) == Ok([])
}

/// O7. A deadline leaves nothing in the caller's mailbox.
pub fn a_deadline_leaves_the_caller_s_mailbox_empty_test() {
  let checked = process.new_subject()
  process.spawn(fn() {
    let late =
      model.new(fn(_, _) {
        process.sleep(30)
        Ok(Recommendation("late", Rules("r", "1"), RuleFired("r"), [], []))
      })
    let outcome =
      model.run(
        isolated.model(
          late,
          within: duration.milliseconds(30),
          heap: lab.heap(),
        ),
        Manifest(refs: [], renderer: "lab-1"),
        model.recorded(context: [], reads: []),
      )
    process.sleep(50)
    process.send(checked, #(outcome, mailbox(process.self())))
  })
  let assert Ok(#(outcome, waiting)) = process.receive(checked, 2000)
  assert waiting == 0
  case outcome {
    Ok(_) | Error(model.Deadline(_)) -> Nil
    Error(other) -> panic as model.describe(other)
  }
}

/// O7. Parallel replay's workers die with their caller.
pub fn replay_workers_die_with_their_caller_test() {
  let started = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      replay.map(lab.numbers(1, 4), 4, fn(_) {
        process.send(started, process.self())
        process.sleep_forever()
      })
    })
  let workers =
    list.map(lab.numbers(1, 4), fn(_) {
      let assert Ok(pid) = process.receive(started, 1000)
      pid
    })
  lab.kill(caller)
  assert lab.wait_until(
    fn() { list.all(workers, fn(pid) { !process.is_alive(pid) }) },
    within: 1000,
  )
}

/// O7. A slow owner is "no answer in time", not "stopped", and
/// `subscribe` says so instead of returning a dead subscription.
pub fn a_slow_owner_is_not_a_stopped_one_test() {
  let s = lab.start()
  suspend(store.owner(s))
  let hints = process.new_subject()
  let outcome = store.subscribe(s, live.ToPoint("p"), hints)
  resume(store.owner(s))
  assert outcome == Error(store.NoAnswerWithin(5000))
  let assert Ok(_) = store.subscribe(s, live.ToPoint("p"), hints)
  // Once the owner is seen gone, the answer is "stopped".
  let monitor = process.monitor(store.owner(s))
  store.stop(s)
  let assert Ok(Nil) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)
  assert store.subscribe(s, live.ToPoint("p"), hints)
    == Error(store.StoreStopped)
}

@external(erlang, "erlang", "suspend_process")
fn suspend_raw(pid: process.Pid) -> Bool

@external(erlang, "erlang", "resume_process")
fn resume_raw(pid: process.Pid) -> Bool

fn suspend(pid: process.Pid) -> Nil {
  let _ = suspend_raw(pid)
  Nil
}

fn resume(pid: process.Pid) -> Nil {
  let _ = resume_raw(pid)
  Nil
}

@external(erlang, "decisions_otp_ffi", "mailbox")
fn mailbox(pid: process.Pid) -> Int
