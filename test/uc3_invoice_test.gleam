//// Use case 3: an invoice. Read back, and a refusal that rolls back and is
//// then kept on the record.

import decisions
import decisions/memory
import decisions/occurrence
import decisions/vocabulary.{
  Approve, Correct, Manifest, ParentRun, Reason, Ref, RunAnswer,
}
import gleam/option.{None}
import gleam/result
import support/invoice.{Invoice}
import support/world

fn context() {
  Manifest(refs: [Ref("message", "m7", "1")], renderer: "invoice-1")
}

fn corrected() {
  Correct(
    Invoice(taker: "clinica-x", cents: 80_000, service_code: "4.22"),
    Reason("wrong_fact", None),
  )
}

pub fn a_corrected_invoice_is_issued_once_and_settled_by_reading_back_test() {
  let w = world.new()
  let recommended =
    invoice.recommend(
      w,
      asked_by: "run-7",
      explained_by: RunAnswer("run-acc-1"),
      from: context(),
    )
  let assert occurrence.Awaiting(_) = recommended.status
  assert recommended.parent == option.Some(ParentRun("run-7"))

  // Felipe corrects the service code. The release happens in the verdict's
  // transaction, and the executor applies the tax context's command once.
  let assert Ok(released) =
    world.in_tx(w, world.open_and_decide(
      invoice.desk(),
      _,
      recommended.id,
      world.felipe,
      corrected(),
    ))
  let assert occurrence.Released(final:, key:, ..) = released.status
  assert final.service_code == "4.22"
  assert released.recommendation.output.service_code == "4.03"
  assert invoice.state(w, key) == Ok("submitted")
  assert invoice.issue_calls(w) == 0

  // The municipality issues it and loses the reply.
  invoice.perform_effects(w)
  assert invoice.state(w, key) == Ok("uncertain")
  assert invoice.issue_calls(w) == 1

  // Settled by reading the outside system back, never by calling again.
  invoice.settle_uncertain(w, key)
  assert invoice.state(w, key) == Ok("issued")
  assert invoice.issue_calls(w) == 1

  // A second verdict is refused, and requests no second effect.
  assert world.in_tx(w, world.open_and_decide(
      invoice.desk(),
      _,
      recommended.id,
      world.caio,
      Approve,
    ))
    == Error(decisions.AlreadyDecided("felipe"))
  invoice.perform_effects(w)
  assert invoice.issue_calls(w) == 1
}

pub fn a_refusal_in_the_verdicts_transaction_rolls_both_back_and_is_recorded_test() {
  let w = world.new()
  let recommended =
    invoice.recommend(
      w,
      asked_by: "run-7",
      explained_by: RunAnswer("run-acc-1"),
      from: context(),
    )
  memory.put(w.db, "tax_id_held:clinica-x", "another party")

  // First request: Felipe opens the card; his ticket outlives the request.
  let assert Ok(card) =
    world.in_tx(w, world.open(invoice.desk(), _, recommended.id, world.felipe))
  let ticket = decisions.ticket(card)

  // Second request: the tax context refuses. Felipe sees why, and the
  // verdict and the release roll back together.
  let refused =
    world.in_tx(w, fn(tx) {
      use card <- result.try(decisions.resume(
        invoice.desk(),
        tx,
        ticket,
        by: world.felipe,
      ))
      decisions.decide(invoice.desk(), tx, card, corrected())
    })
  let assert Error(decisions.ToolRefused(reason:, rollback:)) = refused
  assert reason == "the taker's tax id is held by another party"
  let still = world.read(w, invoice.desk(), recommended.id)
  let assert occurrence.Awaiting(_) = still.status
  assert occurrence.verdict(still) == None
  assert occurrence.refusals(still) == []
  assert world.all(w.db, "effects") == []

  // In a transaction of its own, the refusal is kept on the record. It
  // changes no status: the occurrence still waits.
  let assert Ok(kept) =
    world.in_tx(w, decisions.record_refusal(invoice.desk(), _, rollback))
  let assert [
    #("felipe", Correct(..), "the taker's tax id is held by another party"),
  ] = occurrence.refusals(kept)
  let assert occurrence.Awaiting(_) = kept.status
  assert memory.queue(w.db, "operators") == [recommended.id]
}
