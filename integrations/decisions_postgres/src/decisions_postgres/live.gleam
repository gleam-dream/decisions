//// Live notifications: a process learns that an occurrence changed without
//// asking. Every append (`decisions_append`) sends `NOTIFY` on the channel
//// `decisions_changed` inside the appending transaction, so PostgreSQL
//// delivers it when that transaction commits and never when it rolls back.
//// The listener is one process with a connection of its own, outside the
//// pool, that forwards each notification to the processes subscribed to it.
////
//// **A notification is a hint to read again, and nothing more.** It is
//// lost when the listener's connection drops, when the listener restarts,
//// and when a subscriber's mailbox is gone. When the connection drops, the
//// listener notices within about a second (it checks its connection every
//// 500 ms), opens a new one and listens again; it does not tell subscribers
//// that it was disconnected, and what changed meanwhile is not sent.
////
//// **The subscriber's contract is therefore: listen, and poll.** A client
//// that must not miss a change polls, at an interval it can afford, the
//// positions of the occurrences it holds with
//// `decisions_postgres/queue.positions(db, ids)` (one index lookup per
//// id), and reads again any whose last sequence number moved past what it
//// has seen. Nothing in the record depends on a notification.
////
//// ```gleam
//// import decisions_postgres/live
////
//// // In the application's supervision tree:
//// supervisor.add(live.supervised(pool_config, listener_name))
////
//// // In a process that shows a card:
//// let changes = process.new_subject()
//// live.subscribe(live.named(listener_name), changes, live.Occurrence(id))
//// case process.receive(changes, 30_000) {
////   Ok(change) -> read_again(change.occurrence)
////   Error(Nil) -> poll()
//// }
//// ```

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import pog

/// The channel every append notifies.
pub const channel = "decisions_changed"

/// What a notification says: enough to decide whether to read again.
pub type Change {
  Change(occurrence: String, point: String, status: String, seq: Int)
}

/// Which changes a subscriber receives.
pub type Topic {
  /// Every change.
  Everything
  /// The changes to occurrences of this point.
  Point(name: String)
  /// The changes to this occurrence.
  Occurrence(id: String)
}

/// The listener's messages. Use `subscribe` and `unsubscribe`.
pub opaque type Message {
  Subscribe(subject: Subject(Change), topic: Topic, reply: Subject(Pid))
  Unsubscribe(subject: Subject(Change))
  Notified(payload: String)
  SubscriberDown(pid: Pid)
  /// Time to check the listening connection (`probe_ms`).
  Probe
  Ignored
}

/// A running listener.
pub opaque type Listener {
  Listener(subject: Subject(Message))
}

type State {
  State(
    subscribers: List(#(Subject(Change), Topic)),
    monitors: Dict(Pid, process.Monitor),
    /// The `pgo_notifications` process that holds the connection.
    connection: Pid,
    /// How to start another when it is lost.
    reconnect: fn() -> Result(Pid, String),
    self: Subject(Message),
    /// Probes in a row that found the connection closed.
    lost: Int,
  )
}

/// How often the listener checks its connection. pgo 0.20's
/// `pgo_notifications` does not notice a connection the server closed (it
/// drops `tcp_closed`), so the listener checks the socket itself and, after
/// two probes in a row find it closed, starts a new connection and listens
/// again.
const probe_ms = 500

/// Start a listener with the database settings of `config` (host, port,
/// database, user, password and SSL mode; its pool settings are ignored).
/// The listener is linked to the caller.
pub fn start(config: pog.Config) -> actor.StartResult(Listener) {
  builder(config) |> actor.start
}

/// The listener as a child of the application's supervisor, registered
/// under `name`. `named(name)` reaches it, also after a restart.
pub fn supervised(
  config: pog.Config,
  name: process.Name(Message),
) -> supervision.ChildSpecification(Listener) {
  supervision.worker(fn() {
    builder(config) |> actor.named(name) |> actor.start
  })
}

/// The listener registered under `name`.
pub fn named(name: process.Name(Message)) -> Listener {
  Listener(process.named_subject(name))
}

/// Send `subject` every change about `topic` from now on, until
/// `unsubscribe` or until the subject's owner exits. A subject subscribed
/// again keeps only its latest topic.
///
/// The listener acknowledges the subscription: `Ok(pid)` means it is in
/// place, and `pid` is the listener's process. Subscriptions live only in
/// that process, so a subscriber that must know when it stops receiving
/// monitors it (`process.monitor(pid)`): when the listener exits, its
/// subscriptions are gone; subscribe again to the restarted listener
/// (`named(name)` reaches it) and poll `queue.positions` for what changed
/// meanwhile. `Error(Nil)` means the listener did not answer within 5
/// seconds.
///
/// Nothing bounds a subscriber's mailbox: every change about its topic is
/// sent to it as it happens. A subscriber that cannot keep up chooses a
/// narrower topic, or drains its mailbox and polls instead.
pub fn subscribe(
  listener: Listener,
  subject: Subject(Change),
  to topic: Topic,
) -> Result(Pid, Nil) {
  let reply = process.new_subject()
  process.send(listener.subject, Subscribe(subject:, topic:, reply:))
  process.receive(reply, 5000)
}

/// Stop sending changes to `subject`.
pub fn unsubscribe(listener: Listener, subject: Subject(Change)) -> Nil {
  process.send(listener.subject, Unsubscribe(subject:))
}

@external(erlang, "decisions_postgres_ffi", "listener_connected")
fn connected(connection: Pid) -> Bool

@external(erlang, "decisions_postgres_ffi", "stop_listener")
fn stop_listener(connection: Pid) -> Nil

@external(erlang, "decisions_postgres_ffi", "listen")
fn listen(
  host: String,
  port: Int,
  database: String,
  user: String,
  password: Option(String),
  ssl: pog.Ssl,
  channel: String,
) -> Result(Pid, String)

fn builder(config: pog.Config) -> actor.Builder(State, Message, Listener) {
  actor.new_with_initialiser(10_000, fn(subject) {
    let reconnect = fn() {
      listen(
        config.host,
        config.port,
        config.database,
        config.user,
        config.password,
        config.ssl,
        channel,
      )
    }
    use connection <- result.try(reconnect())
    process.send_after(subject, probe_ms, Probe)
    let selector =
      process.new_selector()
      |> process.select(subject)
      // `{notification, Pid, Ref, Channel, Payload}` from pgo_notifications.
      |> process.select_record(atom.create("notification"), 4, fn(message) {
        decode.run(message, decode.at([4], decode.string))
        |> result.map(Notified)
        |> result.unwrap(Ignored)
      })
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid:, ..) -> SubscriberDown(pid)
          _ -> Ignored
        }
      })
    actor.initialised(State(
      subscribers: [],
      monitors: dict.new(),
      connection:,
      reconnect:,
      self: subject,
      lost: 0,
    ))
    |> actor.selecting(selector)
    |> actor.returning(Listener(subject))
    |> Ok
  })
  |> actor.on_message(handle)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Subscribe(subject:, topic:, reply:) -> {
      process.send(reply, process.self())
      let others = list.filter(state.subscribers, fn(s) { s.0 != subject })
      let monitors = case process.subject_owner(subject) {
        Ok(pid) ->
          case dict.has_key(state.monitors, pid) {
            True -> state.monitors
            False -> dict.insert(state.monitors, pid, process.monitor(pid))
          }
        Error(Nil) -> state.monitors
      }
      actor.continue(
        State(..state, subscribers: [#(subject, topic), ..others], monitors:),
      )
    }
    Unsubscribe(subject:) ->
      actor.continue(
        State(
          ..state,
          subscribers: list.filter(state.subscribers, fn(s) { s.0 != subject }),
        ),
      )
    SubscriberDown(pid:) ->
      actor.continue(
        State(
          ..state,
          subscribers: list.filter(state.subscribers, fn(s) {
            process.subject_owner(s.0) != Ok(pid)
          }),
          monitors: dict.delete(state.monitors, pid),
        ),
      )
    Notified(payload:) -> {
      case json.parse(payload, change_decoder()) {
        Ok(change) ->
          list.each(state.subscribers, fn(s) {
            case wants(s.1, change) {
              True -> process.send(s.0, change)
              False -> Nil
            }
          })
        // A payload this version does not understand is no change.
        Error(_) -> Nil
      }
      actor.continue(state)
    }
    Probe -> {
      process.send_after(state.self, probe_ms, Probe)
      case connected(state.connection), state.lost {
        True, _ -> actor.continue(State(..state, lost: 0))
        False, 0 -> actor.continue(State(..state, lost: 1))
        False, _ -> {
          stop_listener(state.connection)
          case state.reconnect() {
            Ok(connection) ->
              actor.continue(State(..state, connection:, lost: 0))
            Error(reason) ->
              actor.stop_abnormal(
                "the listener could not reconnect: " <> reason,
              )
          }
        }
      }
    }
    Ignored -> actor.continue(state)
  }
}

fn wants(topic: Topic, change: Change) -> Bool {
  case topic {
    Everything -> True
    Point(name:) -> name == change.point
    Occurrence(id:) -> id == change.occurrence
  }
}

fn change_decoder() -> decode.Decoder(Change) {
  use occurrence <- decode.field("id", decode.string)
  use point <- decode.field("point", decode.string)
  use status <- decode.field("status", decode.string)
  use seq <- decode.field("seq", decode.int)
  decode.success(Change(occurrence:, point:, status:, seq:))
}
