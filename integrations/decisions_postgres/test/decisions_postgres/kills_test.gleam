//// Condition B on real connections: a process killed inside a
//// transaction leaves nothing, a worker killed after its commit and before
//// Grind heard of it is delivered again and does nothing twice, and a
//// restart loses no wake-up.

import decisions
import decisions/occurrence
import decisions/vocabulary.{Approve}
import decisions_postgres
import decisions_postgres/telemetry
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import kit
import pog
import sinal

/// An executor that writes its effect, then, the first time it runs for an
/// output marked `block`, tells `parent` it is inside the transaction and
/// waits to be killed.
fn blocking(parent: process.Subject(process.Pid)) {
  fn(tx: pog.Connection, released: decisions.Released(String)) {
    let written = kit.record_effect(tx, released)
    case
      string.contains(decisions.output(released), "block")
      && kit.once("block:" <> decisions.occurrence_of(released))
    {
      True -> {
        process.send(parent, process.self())
        process.sleep_forever()
        written
      }
      False -> written
    }
  }
}

/// B2: the validator's process is killed after the tool wrote and before
/// the verdict committed. No effect exists, the occurrence still waits,
/// and a second verdict releases it with one effect.
pub fn killed_inside_the_verdict_after_the_tool_wrote_test() {
  let #(name, store) = kit.store()
  let inside = process.new_subject()
  let spec = kit.Spec(..kit.spec("b2"), execute: blocking(inside))
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let proposal =
    decisions.proposal(
      trigger: vocabulary.Trigger("test", kit.tag("t")),
      about: kit.ana,
      context: vocabulary.Manifest(refs: [], renderer: "test-1"),
      recommending: vocabulary.Recommendation(
        output: spec.name <> "@block",
        by: vocabulary.Rules("test", "1"),
        explanation: vocabulary.RuleFired("test"),
        signals: [],
        reads: [],
      ),
    )
  let assert Ok(waiting) = kit.tx(env, decisions.recommend(desk, _, proposal))
  let victim =
    process.spawn_unlinked(fn() {
      kit.tx(env, kit.open_and_decide(
        desk,
        _,
        waiting.id,
        kit.finance("bia"),
        Approve,
      ))
    })
  let assert Ok(pid) = process.receive(inside, 10_000)
  assert pid == victim
  // While it is open, its write is invisible to everyone else.
  assert kit.effects_of(env.db, waiting.id) == 0
  process.kill(victim)
  let assert True =
    kit.eventually(5000, fn() {
      case kit.tx(env, decisions.read(desk, _, occurrence: waiting.id)) {
        Ok(known) ->
          case known.status {
            occurrence.Awaiting(_) -> True
            _ -> False
          }
        Error(_) -> False
      }
    })
  assert kit.effects_of(env.db, waiting.id) == 0
  // The killed validator's showing is gone with its transaction, so the
  // record holds only the recommendation and the policy's answer.
  let assert Ok(known) =
    kit.tx(env, decisions.read(desk, _, occurrence: waiting.id))
  assert list.length(known.entries) == 2
  let assert Ok(released) =
    kit.tx(env, kit.open_and_decide(
      desk,
      _,
      waiting.id,
      kit.finance("caio"),
      Approve,
    ))
  let assert occurrence.Released(..) = released.status
  assert kit.effects_of(env.db, waiting.id) == 1
  kit.check(env, [desk])
}

/// B1, killed: a recommender killed inside its transaction after the tool
/// wrote leaves no occurrence and no effect; three later deliveries of the
/// same trigger make one occurrence and one effect.
pub fn a_recommender_killed_mid_transaction_leaves_nothing_test() {
  let #(name, store) = kit.store()
  let inside = process.new_subject()
  let spec =
    kit.Spec(
      ..kit.spec("b1k"),
      policy: kit.proceed(),
      execute: blocking(inside),
    )
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let key = kit.tag("key")
  let blocked = proposal_with(spec.name, spec.name <> "@block")
  let victim =
    process.spawn_unlinked(fn() {
      kit.tx(env, decisions.recommend_once(desk, _, key:, proposal: blocked))
    })
  let assert Ok(_) = process.receive(inside, 10_000)
  process.kill(victim)
  // This load waits for the killed transaction's lock on the key, so it
  // answers only once that transaction rolled back.
  let assert Error(decisions_postgres.Refused(decisions.UnknownOccurrence)) =
    kit.tx(env, decisions.read(desk, _, occurrence: key))
  assert kit.effects_of(env.db, key) == 0
  let again = proposal_with(spec.name, spec.name <> "@again")
  let results =
    kit.race(3, 30_000, fn(_) {
      kit.tx(env, decisions.recommend_once(desk, _, key:, proposal: again))
    })
  assert list.all(results, fn(result) {
    case result {
      Ok(found) -> found.id == key
      Error(_) -> False
    }
  })
  assert kit.effects_of(env.db, key) == 1
  kit.check(env, [desk])
}

fn proposal_with(point: String, output: String) -> decisions.Proposal(String) {
  let _ = point
  decisions.proposal(
    trigger: vocabulary.Trigger("test", kit.tag("t")),
    about: kit.ana,
    context: vocabulary.Manifest(refs: [], renderer: "test-1"),
    recommending: vocabulary.Recommendation(
      output:,
      by: vocabulary.Rules("test", "1"),
      explanation: vocabulary.RuleFired("test"),
      signals: [],
      reads: [],
    ),
  )
}

/// A wake-up worker killed after its transaction committed and before
/// Grind recorded the outcome. Grind replays the job when the attempt's
/// lease expires; the replay finds the wake-up delivered and does nothing.
/// The hold is released once.
pub fn a_worker_killed_after_commit_is_replayed_and_does_nothing_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(
      ..kit.spec("killed_worker"),
      policy: kit.proceed(),
      hold: Some(duration.milliseconds(200)),
    )
  let desk = kit.desk(store, spec)
  let options =
    kit.Options(..kit.delivering(), deadline: duration.milliseconds(1200))
  use env <- kit.run(name, store, options, [decisions.waker(desk)], [])
  // The handler of this event runs in the worker's process, after the
  // commit and before the worker answers Grind: killing it there is a
  // worker lost at exactly that moment.
  let killer =
    sinal.observe(telemetry.wake_delivered(), fn(_, delivered) {
      case delivered.point == spec.name && kit.once("killer:" <> spec.name) {
        True -> process.kill(process.self())
        False -> Nil
      }
    })
  let assert Ok(held) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert True =
    kit.eventually(20_000, fn() {
      case kit.jobs(env, "decisions.wake") {
        [#("succeeded", deliveries)] -> deliveries >= 2
        _ -> False
      }
    })
  let _ = sinal.detach(killer)
  let assert Ok(known) =
    kit.tx(env, decisions.read(desk, _, occurrence: held.id))
  let assert occurrence.Released(..) = known.status
  assert kit.effects_of(env.db, held.id) == 1
  kit.check(env, [desk])
}

/// B4: thirty holds and ten waiting refunds, and the node stops before the
/// holds end. A new node over the same database releases each hold once;
/// the refunds still wait with their deadline's wake-up pending.
pub fn a_restart_with_holds_pending_loses_nothing_test() {
  let #(first_name, first_store) = kit.store()
  let held_spec =
    kit.Spec(
      ..kit.spec("b4_held"),
      policy: kit.proceed(),
      hold: Some(duration.milliseconds(1500)),
    )
  let waiting_spec =
    kit.Spec(..kit.spec("b4_waiting"), validity: Some(duration.hours(1)))
  let held_desk = kit.desk(first_store, held_spec)
  let waiting_desk = kit.desk(first_store, waiting_spec)
  let first =
    kit.start(
      first_name,
      first_store,
      kit.delivering(),
      [decisions.waker(held_desk), decisions.waker(waiting_desk)],
      [],
      None,
    )
  let held =
    list.map(kit.int_range(30), fn(_) {
      let assert Ok(held) =
        kit.tx(first, decisions.recommend(
          held_desk,
          _,
          kit.proposal(held_spec.name, kit.ana),
        ))
      held.id
    })
  list.each(kit.int_range(10), fn(_) {
    let assert Ok(_) =
      kit.tx(first, decisions.recommend(
        waiting_desk,
        _,
        kit.proposal(waiting_spec.name, kit.ana),
      ))
  })
  kit.stop(first)
  // A new node: new runtime, new pool, desks built again.
  let #(second_name, second_store) = kit.store()
  let held_desk = kit.desk(second_store, held_spec)
  let waiting_desk = kit.desk(second_store, waiting_spec)
  let second =
    kit.start(
      second_name,
      second_store,
      kit.delivering(),
      [decisions.waker(held_desk), decisions.waker(waiting_desk)],
      [],
      Some(first.schema),
    )
  // Every hold's job acknowledged (30 succeeded) and only the ten
  // deadlines still scheduled: nothing else will deliver a hold.
  let assert True =
    kit.eventually(20_000, fn() {
      let jobs = kit.jobs(second, "decisions.wake")
      list.count(jobs, fn(job) { job.0 == "succeeded" }) == 30
      && list.count(jobs, fn(job) { job.0 == "scheduled" }) == 10
      && list.length(jobs) == 40
    })
  assert kit.effects(second.db, held_spec.name) == 30
  assert list.all(held, fn(id) { kit.effects_of(second.db, id) == 1 })
  let summary = kit.check(second, [held_desk, waiting_desk])
  assert summary.released == 30
  assert summary.occurrences == 40
  kit.stop(second)
}
