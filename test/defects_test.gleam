//// One test per defect the prototype's PostgreSQL and agent builds found,
//// numbered as in the lab's FINDINGS-2.md "What must change in the
//// design". Each fails without its fix.

import decisions
import decisions/entry
import decisions/memory.{type Memory}
import decisions/model
import decisions/occurrence
import decisions/policy.{
  AnyoneHolding, Ask, Never, OwnAct, Policy, Proceed, When,
}
import decisions/store
import decisions/vocabulary.{
  type Ref, Agent, Approve, Manifest, Person, Recommendation, Ref, RunAnswer,
  Trigger,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import support/refund.{Refund}
import support/reply
import support/world

fn ask() {
  Policy(version: 1, rules: [], otherwise: Ask(AnyoneHolding("finance")))
}

fn own_act_proceeds() {
  Policy(
    version: 1,
    rules: [When(OwnAct, Proceed(Never, None))],
    otherwise: Ask(AnyoneHolding("finance")),
  )
}

fn request(desk, w: world.World, fee: String) {
  let assert Ok(waiting) =
    world.in_tx(w, refund.request(
      desk,
      _,
      Trigger(kind: "ticket", id: fee),
      Agent(kind: "billing", version: "3"),
      Refund(fee:, cents: 9000),
    ))
  waiting
}

/// 1. `decide` refuses a verdict after the validity has passed, though the
/// wake-up that expires the occurrence was never delivered.
pub fn defect_1_a_verdict_after_the_deadline_is_refused_test() {
  let w = world.new()
  let desk =
    refund.desk_of(
      refund.point() |> decisions.valid_for(duration.hours(1)),
      ask(),
    )
  let waiting = request(desk, w, "fee-1")
  world.at(w, duration.minutes(61))
  assert world.in_tx(w, world.open_and_decide(
      desk,
      _,
      waiting.id,
      world.bia,
      Approve,
    ))
    == Error(decisions.NotAwaiting)
  assert refund.refunds(w) == []
  // A consulted point's answer after the deadline is refused alike.
  assert world.in_tx(
      w,
      decisions.inform(desk, _, occurrence: waiting.id, from: "x", facts: []),
    )
    == Error(decisions.NotAwaiting)
}

/// 2. The clock is read after the occurrence is loaded and locked, and an
/// entry is never stored earlier than the one before it. Here another
/// writer appends at +10 s while this verb waits for the lock, and this
/// verb's clock then reads +5 s.
pub fn defect_2_entries_are_stored_in_time_order_test() {
  let w = world.new()
  let plain = refund.desk(ask())
  let waiting = request(plain, w, "fee-2")
  let base = memory.port()
  let interleaving =
    store.Port(..base, load: fn(tx: Memory, id) {
      case memory.get(tx, "interleave") {
        Ok("yes") -> {
          memory.put(tx, "interleave", "")
          world.at(w, duration.seconds(10))
          let assert Ok(_) =
            decisions.open(
              plain,
              tx,
              occurrence: id,
              by: world.felipe,
              latest: world.unchanged,
            )
          world.at(w, duration.seconds(5))
          Nil
        }
        _ -> Nil
      }
      base.load(tx, id)
    })
  let desk =
    decisions.desk(
      refund.point(),
      drives: fn(_) { refund.refund_fee() },
      under: fn(_) { Ok(ask()) },
      over: interleaving,
    )
  memory.put(w.db, "interleave", "yes")
  let assert Ok(_) =
    world.in_tx(w, fn(tx) {
      decisions.open(
        desk,
        tx,
        occurrence: waiting.id,
        by: world.bia,
        latest: world.unchanged,
      )
    })
  let times =
    list.map(memory.entries(w.db, waiting.id), fn(stored) { stored.at })
  assert list.length(times) == 4
  assert list.sort(times, timestamp.compare) == times
}

/// 3. `wake` says whether anything was due. A job that arrives before the
/// hold ends is told when to come back, writes nothing, and the hold is
/// not lost.
pub fn defect_3_an_early_wake_up_says_when_to_come_back_test() {
  let w = world.new()
  let drafted =
    reply.draft(w, "m1", "run-1", Manifest(refs: [], renderer: "reply-1"))
  let assert Ok(held) =
    world.in_tx(w, world.open_and_decide(
      reply.desk(),
      _,
      drafted.id,
      world.felipe,
      Approve,
    ))
  let assert occurrence.Held(until:, ..) = held.status
  let entries = memory.entries(w.db, drafted.id)

  // The job queue's clock is ahead: the job arrives a second early.
  world.at(w, duration.seconds(4))
  assert world.in_tx(w, decisions.wake(reply.desk(), _, occurrence: drafted.id))
    == Ok(decisions.NotDue(until))
  let #(_, handler) = decisions.waker(reply.desk())
  assert world.in_tx(w, handler(_, drafted.id)) == Ok(Some(until))
  assert memory.entries(w.db, drafted.id) == entries
  assert reply.outbox(w) == []

  // Delivered again at the time it named, it releases.
  world.at(w, duration.seconds(5))
  let assert Ok(decisions.Woken(released)) =
    world.in_tx(w, decisions.wake(reply.desk(), _, occurrence: drafted.id))
  let assert occurrence.Released(..) = released.status
  assert world.in_tx(w, handler(_, drafted.id)) == Ok(None)
  assert reply.outbox(w) == [reply.draft_text]
}

/// 4. Superseding contains an occurrence it cannot read: the others about
/// that subject are still superseded, and the unreadable one is reported.
pub fn defect_4_one_unreadable_occurrence_does_not_stop_superseding_test() {
  let w = world.new()
  let first =
    reply.draft(w, "m1", "run-1", Manifest(refs: [], renderer: "reply-1"))
  let second =
    reply.draft(w, "m2", "run-2", Manifest(refs: [], renderer: "reply-1"))
  let third =
    reply.draft(w, "m3", "run-3", Manifest(refs: [], renderer: "reply-1"))
  memory.tamper(w.db, second.id, 1, "{\"not\":\"an entry\"}")

  let assert Ok(decisions.Supersession(expired:, not_begun: [], unreadable:)) =
    world.in_tx(w, decisions.happened(
      reply.desk(),
      _,
      "customer.message",
      about: world.ana,
    ))
  assert list.map(expired, fn(o) { o.id }) == [first.id, third.id]
  let assert [#(id, decisions.Unreadable(_))] = unreadable
  assert id == second.id
  // The unreadable record is visible as such to every other verb.
  let assert Error(decisions.Unreadable(_)) =
    world.in_tx(w, decisions.read(reply.desk(), _, occurrence: second.id))
}

/// 5. Admission locks an occurrence that does not exist yet: the port's
/// `load` is asked for the key, and so locks it, before anything is
/// appended under it.
pub fn defect_5_admission_loads_and_locks_the_key_first_test() {
  let w = world.new()
  let base = memory.port()
  let logged =
    store.Port(
      ..base,
      load: fn(tx: Memory, id) {
        world.push(tx, "calls", "load " <> id)
        base.load(tx, id)
      },
      append: fn(tx: Memory, id, head, entries) {
        world.push(tx, "calls", "append " <> id)
        base.append(tx, id, head, entries)
      },
    )
  let desk =
    decisions.desk(
      refund.point(),
      drives: fn(_) { refund.refund_fee() },
      under: fn(_) { Ok(ask()) },
      over: logged,
    )
  let proposal =
    decisions.proposal(
      trigger: Trigger("ticket", "t5"),
      about: world.clinica,
      context: Manifest(refs: [], renderer: "refund-1"),
      recommending: Recommendation(
        Refund("fee-5", 100),
        Agent("billing", "3"),
        RunAnswer("r"),
        [],
        [],
      ),
    )
  let assert Ok(_) =
    world.in_tx(w, decisions.recommend_once(desk, _, key: "refund-5", proposal:))
  assert world.all(w.db, "calls") == ["load refund-5", "append refund-5"]
}

/// 6. The guard and the gated tool run inside a savepoint. A tool that
/// writes and then refuses after a hold leaves nothing, and the occurrence
/// ends refused in the same transaction.
pub fn defect_6_a_tool_that_writes_then_refuses_leaves_nothing_test() {
  let w = world.new()
  let tool =
    decisions.Gated(
      name: "refund_fee",
      guard: fn(_, _) { Ok([]) },
      execute: fn(tx, _) {
        world.push(tx, "refunds", "half-written")
        Error(decisions.Refuse("the ledger is closed"))
      },
    )
  let desk =
    decisions.desk(
      refund.point() |> decisions.with_hold(duration.minutes(1)),
      drives: fn(_) { tool },
      under: fn(_) { Ok(own_act_proceeds()) },
      over: memory.port(),
    )
  let assert Ok(held) =
    world.in_tx(w, refund.request(
      desk,
      _,
      Trigger("ticket", "t6"),
      Person("bia"),
      Refund("fee-6", 100),
    ))
  let assert occurrence.Held(..) = held.status
  world.at(w, duration.minutes(1))
  assert world.deliver_due(w, [decisions.waker(desk)]) == 1
  assert world.read(w, desk, held.id).status
    == occurrence.Refused("the ledger is closed")
  assert refund.refunds(w) == []
}

/// 7. The head carries the due time, the arrival time and who approved,
/// so a queue never decodes an entry.
pub fn defect_7_the_head_carries_due_arrival_and_approvals_test() {
  let w = world.new()
  let desk =
    refund.desk_of(
      refund.point() |> decisions.valid_for(duration.hours(2)),
      Policy(
        version: 1,
        rules: [],
        otherwise: Ask(policy.Several(2, AnyoneHolding("finance"))),
      ),
    )
  let waiting = request(desk, w, "fee-7")
  let assert Ok(_) =
    world.in_tx(w, world.open_and_decide(
      desk,
      _,
      waiting.id,
      world.bia,
      Approve,
    ))
  let assert Ok(head) = list.key_find(memory.heads(w.db), waiting.id)
  assert head.due == Some(timestamp.add(world.t0(), duration.hours(2)))
  assert head.arrived == world.t0()
  assert head.approved == ["bia"]
  assert head.awaiting == ["finance"]
}

/// 8. The record holds the reads the model received. Observing is the
/// default; a model that reports what it received is believed, so a read
/// it made and never received is not on the record.
pub fn defect_8_a_reported_read_is_believed_test() {
  let w = world.new()
  let sources =
    world.capturing(w, "run-8", fn(_) { Error("no context") }, fn(_, argument) {
      Ok("balance " <> argument)
    })
  let reads_twice = fn(report: Bool) {
    fn(_context, sources: model.Sources) {
      // The tool read a balance and then failed, so the model never
      // received it; the retried call is what it received.
      use _lost <- result.try(sources.read("balance", "first"))
      use kept <- result.try(sources.read("balance", "second"))
      Ok(
        Recommendation(
          output: "ok",
          by: Agent("support", "1"),
          explanation: RunAnswer("run-8"),
          signals: [],
          reads: case report {
            True -> [kept.ref]
            False -> []
          },
        ),
      )
    }
  }
  let context = Manifest(refs: [], renderer: "r")
  let assert Ok(observed) =
    model.run(model.new(reads_twice(False)), context, sources)
  assert list.map(observed.reads, fn(ref) { ref.id }) == ["first", "second"]
  let assert Ok(reported) =
    model.run(model.reporting(reads_twice(True)), context, sources)
  assert list.map(reported.reads, fn(ref) { ref.id }) == ["second"]
}

/// 9. Drift is flagged for a read that changed, not only for a context
/// reference.
pub fn defect_9_a_changed_read_is_flagged_test() {
  let w = world.new()
  let desk = refund.desk(ask())
  let read = Ref("balance", "clinica-x", "r1")
  let assert Ok(waiting) =
    world.in_tx(w, decisions.recommend(
      desk,
      _,
      decisions.proposal(
        trigger: Trigger("ticket", "t9"),
        about: world.clinica,
        context: Manifest(
          refs: [Ref("message", "m9", "1")],
          renderer: "refund-1",
        ),
        recommending: Recommendation(
          Refund("fee-9", 100),
          Agent("billing", "3"),
          RunAnswer("r"),
          [],
          [read],
        ),
      ),
    ))
  let latest = fn(ref: Ref) {
    case ref.kind {
      "balance" -> "r2"
      _ -> ref.revision
    }
  }
  let assert Ok(card) =
    world.in_tx(w, decisions.open(
      desk,
      _,
      occurrence: waiting.id,
      by: world.bia,
      latest:,
    ))
  assert occurrence.drift(decisions.shown(card))
    == [Ref("balance", "clinica-x", "r2")]
  let assert Ok(last) = list.last(decisions.shown(card).entries)
  let assert entry.Opened(drifted: [Ref(revision: "r2", ..)], ..) = last.event
}

@external(erlang, "decisions_test_ffi", "table_count")
fn table_count() -> Int

@external(erlang, "decisions_test_ffi", "stash")
fn stash(value: a) -> Nil

@external(erlang, "decisions_test_ffi", "unstash")
fn unstash() -> fn(String, String) -> Result(model.Captured, model.Failure)

/// 10. A model that raises leaves nothing behind and is a typed failure,
/// and a read made after the model returned does not crash.
pub fn defect_10_a_raising_model_is_contained_test() {
  let w = world.new()
  let sources =
    world.capturing(w, "run-10", fn(_) { Error("no context") }, fn(_, argument) {
      Ok("balance " <> argument)
    })
  let context = Manifest(refs: [], renderer: "r")
  let before = table_count()
  let raising =
    model.new(fn(_, sources: model.Sources) {
      let _ = sources.read("balance", "first")
      panic as "the provider client crashed"
    })
  let assert Error(model.Raised(reason)) = model.run(raising, context, sources)
  assert string.contains(reason, "the provider client crashed")
  assert table_count() == before

  // A model that keeps its sources and reads after it returned.
  let leaky =
    model.new(fn(_, sources: model.Sources) {
      stash(sources.read)
      Ok(
        Recommendation("ok", Agent("support", "1"), RunAnswer("run-10"), [], []),
      )
    })
  let assert Ok(recommendation) = model.run(leaky, context, sources)
  assert recommendation.reads == []
  let late = unstash()
  let assert Ok(captured) = late("balance", "late")
  assert captured.body == "balance late"
  assert table_count() == before
}

/// A structured failure: a caller decides on a retry without reading text.
pub fn failures_say_whether_a_retry_can_help_test() {
  assert model.retryable(model.Raised("x"))
  assert model.retryable(model.Deadline(duration.seconds(30)))
  assert model.retryable(model.Undecodable("x"))
  assert model.retryable(model.ReadFailed("balance", "x", "timeout"))
  assert !model.retryable(model.Declined("no stage answered"))
  assert !model.retryable(model.NotRecorded("balance", "x"))
  let empty = model.cascade([])
  assert model.run(empty, Manifest([], "r"), model.recorded([], []))
    == Error(model.Declined("no stage of the cascade answered"))
}

/// A failed attempt gets an entry of its own, in a transaction of its own,
/// before any recommendation; the recommendation that follows keeps it.
pub fn a_failed_attempt_is_on_the_record_test() {
  let w = world.new()
  let desk = refund.desk(ask())
  let attempt = fn(failure) {
    world.in_tx(w, decisions.record_failure(
      desk,
      _,
      key: "refund-11",
      trigger: Trigger("ticket", "t11"),
      about: world.clinica,
      failure:,
    ))
  }
  let assert Ok([_]) = attempt(model.Deadline(duration.seconds(30)))
  let assert Ok([_, second]) = attempt(model.Raised("crashed"))
  assert second.failure == model.Raised("crashed")
  let assert Error(decisions.NotRecommended([_, _])) =
    world.in_tx(w, decisions.read(desk, _, occurrence: "refund-11"))
  let assert Ok(head) = list.key_find(memory.heads(w.db), "refund-11")
  assert head.status == store.Pending

  let assert Ok(recommended) =
    world.in_tx(w, decisions.recommend_once(
      desk,
      _,
      key: "refund-11",
      proposal: decisions.proposal(
        trigger: Trigger("ticket", "t11"),
        about: world.clinica,
        context: Manifest(refs: [], renderer: "refund-1"),
        recommending: Recommendation(
          Refund("fee-11", 100),
          Agent("billing", "3"),
          RunAnswer("r"),
          [],
          [],
        ),
      ),
    ))
  assert list.map(recommended.attempts, fn(a) { a.failure })
    == [model.Deadline(duration.seconds(30)), model.Raised("crashed")]
  let assert occurrence.Awaiting(_) = recommended.status
  assert list.map(recommended.entries, fn(e) { e.seq }) == [1, 2, 3, 4]

  // Once something is recommended, a late failure is not recorded.
  let assert Ok([_, _]) = attempt(model.Raised("late"))
  assert list.length(memory.entries(w.db, "refund-11")) == 4
}
