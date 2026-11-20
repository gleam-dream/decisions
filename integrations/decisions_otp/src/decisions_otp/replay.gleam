//// A replay spread over processes. It has no deadline of its own: a
//// candidate that hangs holds its worker for ever. Give a candidate a
//// deadline by isolating it first,
//// `replay.replay(examples, isolated.model(candidate, within: duration.seconds(5)), ..)`,
//// so that an example it does not answer in time is unanswered with
//// `model.Deadline`. The workers die with the caller.
////
//// A replay spread over processes. A replay is a pure function of each
//// self-contained example (`decisions/learning.replay_one`), so it runs
//// on every core and adds up to the same tally as `learning.replay`, with
//// the unanswered examples in the same order.
////
//// ```gleam
//// import decisions_otp/replay
////
//// let scored = replay.replay(examples, candidate, same: fn(a, b) { a == b }, across: 8)
//// ```

import decisions/learning.{type Example, type Replay, Replay}
import decisions/model.{type Model}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string

/// `learning.replay` over at most `across` processes at once. Each
/// process replays a contiguous share of the examples; the shares are
/// merged in order. A process that dies (rather than a candidate that
/// raises, which `learning.replay_one` already reports) leaves its
/// examples unanswered with `model.Raised`.
///
/// Each share copies `candidate`, and every heap term its function
/// captures, into its process, and its examples with it; a copy does not
/// keep sharing. A binary larger than 64 bytes is reference-counted, so
/// only a reference to it is copied. Keep the candidate small: build heavy
/// heap terms, such as the codec of a structured answer, inside the
/// model's function.
pub fn replay(
  examples: List(Example(o)),
  candidate: Model(o),
  same same: fn(o, o) -> Bool,
  across across: Int,
) -> Replay {
  let across = int.max(1, across)
  let size = int.max(1, { list.length(examples) + across - 1 } / across)
  let shares = list.sized_chunk(examples, size)
  map(shares, across, fn(share) {
    list.map(share, learning.replay_one(_, candidate, same:)) |> learning.merge
  })
  |> list.zip(shares)
  |> list.map(fn(pair) {
    case pair {
      #(Ok(replay), _) -> replay
      #(Error(reason), share) ->
        Replay(
          tally: learning.nothing,
          unanswered: list.map(share, fn(example) {
            #(example.known.id, model.Raised(reason))
          }),
        )
    }
  })
  |> learning.merge
}

/// Run `work` on each item, in processes of their own, at most `across`
/// at once, and return the results in the items' order. An item whose
/// process exits without answering is `Error` with the exit reason. The
/// processes are not linked to the caller, so one that dies never takes
/// the caller down; a watcher kills them all if the caller dies first. It
/// has no deadline: give `work` one where it can hang.
pub fn map(
  items: List(a),
  across: Int,
  work: fn(a) -> b,
) -> List(Result(b, String)) {
  let indexed = list.index_map(items, fn(item, index) { #(index, item) })
  let reply = process.new_subject()
  let watcher = watch(process.self())
  let #(first, rest) = list.split(indexed, int.max(1, across))
  let running = list.map(first, start(_, reply, work, watcher))
  let done = collect(running, rest, reply, work, watcher, [])
  process.send(watcher, Finished)
  done
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.map(fn(pair) { pair.1 })
}

type Running {
  Running(index: Int, monitor: process.Monitor)
}

type Done(b) {
  Answered(index: Int, value: b)
  Died(monitor: process.Monitor, reason: String)
}

type Watched {
  Started(process.Pid)
  Finished
}

/// A process that kills every worker it is told of when `caller` dies,
/// and ends when told the map finished.
fn watch(caller: process.Pid) -> process.Subject(Watched) {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let told = process.new_subject()
    process.send(ready, told)
    let on_caller = process.monitor(caller)
    watching(told, on_caller, [])
  })
  case process.receive(ready, 5000) {
    Ok(told) -> told
    Error(Nil) -> panic as "decisions_otp/replay: the watcher did not start"
  }
}

fn watching(
  told: process.Subject(Watched),
  on_caller: process.Monitor,
  workers: List(process.Pid),
) -> Nil {
  let next =
    process.new_selector()
    |> process.select_map(told, fn(watched) { Ok(watched) })
    |> process.select_specific_monitor(on_caller, fn(_) { Error(Nil) })
    |> process.selector_receive_forever
  case next {
    Ok(Started(pid)) -> watching(told, on_caller, [pid, ..workers])
    Ok(Finished) -> Nil
    Error(Nil) -> list.each(workers, process.kill)
  }
}

fn start(
  pair: #(Int, a),
  reply: process.Subject(#(Int, b)),
  work: fn(a) -> b,
  watcher: process.Subject(Watched),
) -> Running {
  let #(index, item) = pair
  let pid =
    process.spawn_unlinked(fn() { process.send(reply, #(index, work(item))) })
  process.send(watcher, Started(pid))
  Running(index:, monitor: process.monitor(pid))
}

fn collect(
  running: List(Running),
  waiting: List(#(Int, a)),
  reply: process.Subject(#(Int, b)),
  work: fn(a) -> b,
  watcher: process.Subject(Watched),
  done: List(#(Int, Result(b, String))),
) -> List(#(Int, Result(b, String))) {
  case running {
    [] -> done
    _ -> {
      let selector =
        list.fold(
          running,
          process.new_selector()
            |> process.select_map(reply, fn(pair) { Answered(pair.0, pair.1) }),
          fn(selector, r) {
            process.select_specific_monitor(selector, r.monitor, fn(down) {
              case down {
                process.ProcessDown(reason:, ..) ->
                  Died(r.monitor, string.inspect(reason))
                process.PortDown(reason:, ..) ->
                  Died(r.monitor, string.inspect(reason))
              }
            })
          },
        )
      let #(finished, result) = case
        process.selector_receive_forever(selector)
      {
        Answered(index:, value:) -> #(
          list.find(running, fn(r) { r.index == index }),
          #(index, Ok(value)),
        )
        Died(monitor:, reason:) -> {
          let found = list.find(running, fn(r) { r.monitor == monitor })
          #(found, case found {
            Ok(r) -> #(r.index, Error(reason))
            Error(Nil) -> #(-1, Error(reason))
          })
        }
      }
      case finished {
        // A late exit of a process that already answered.
        Error(Nil) -> collect(running, waiting, reply, work, watcher, done)
        Ok(gone) -> {
          process.demonitor_process(gone.monitor)
          let running = list.filter(running, fn(r) { r.index != gone.index })
          let #(running, waiting) = case waiting {
            [] -> #(running, [])
            [next, ..rest] -> #(
              [start(next, reply, work, watcher), ..running],
              rest,
            )
          }
          collect(running, waiting, reply, work, watcher, [result, ..done])
        }
      }
    }
  }
}
