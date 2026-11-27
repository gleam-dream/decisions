//// Showing a person the same context the model had. One function reads
//// the context, for the model and for the card. The model's reads are
//// captured as evidence before it sees them, so after the world changes
//// the card still shows what the model had, and flags what changed.

// snips-start: same-context
import decisions
import decisions/memory.{type Memory, type Tx}
import decisions/model.{type Reader, type Sources, Sources}
import decisions/occurrence
import decisions/view.{type View}
import decisions/vocabulary.{
  type Manifest, type Ref, Manifest, ModelCall, Receipt, Recommendation, Ref,
  Trigger,
}
import decisions_usage/clinic.{type Refund, Refund}
import decisions_usage/first_point
import gleam/result

/// What the billing model needs to decide a refund.
pub type Dossier {
  Dossier(message: String, balance: String)
}

/// The one function that reads the context: the model and the card both
/// get their `Dossier` from it.
pub fn read_dossier() -> Reader(Dossier) {
  fn(context: Manifest, sources: Sources) {
    use message <- result.try(case context.refs {
      [ref, ..] -> sources.resolve(ref)
      [] -> Error(model.Declined("the context names no message"))
    })
    use balance <- result.try(sources.read("balance", "ana"))
    Ok(Dossier(message:, balance: balance.body))
  }
}

pub fn billing_model() -> model.Model(Refund) {
  model.over(read_dossier(), fn(dossier: Dossier) {
    let cents = case dossier.balance {
      "overdue 80.00" -> 8000
      _ -> 0
    }
    Ok(
      Recommendation(
        output: Refund(fee: "late-fee-2026-10", cents:),
        by: ModelCall(configuration: "billing-llm", version: "2026-11"),
        explanation: Receipt(Ref("llm_call", "call-7", "1")),
        signals: [],
        reads: [],
      ),
    )
  })
}

/// Sources in production: a context reference resolves from the store, and
/// a read is captured as evidence before the model sees it.
pub fn live(store: Memory, balance: fn() -> Result(String, String)) -> Sources {
  Sources(
    resolve: fn(ref: Ref) {
      memory.transaction(store, memory.get(_, "message:" <> ref.id))
      |> result.replace_error(model.ReadFailed(
        ref.kind,
        ref.id,
        "no such message",
      ))
    },
    read: fn(name, argument) {
      memory.transaction(store, model.capture(
        memory.evidence(),
        _,
        source: name,
        request: argument,
        fetch: balance,
      ))
      |> result.map_error(model.ReadFailed(name, argument, _))
    },
  )
}

/// What the record holds, by reference: the content as it was read, in
/// the caller's transaction.
pub fn recorded(tx: Tx) -> fn(Ref) -> Result(String, model.Failure) {
  fn(ref: Ref) {
    case ref.kind {
      "message" ->
        memory.get(tx, "message:" <> ref.id) |> result.replace_error(Nil)
      _ -> memory.evidence().get(tx, ref) |> result.replace_error(Nil)
    }
    |> result.replace_error(model.NotRecorded(ref.kind, ref.id))
  }
}

/// Felipe's card: the same `Dossier` the model had, and the document a
/// page renders, with each input as read and what changed since.
pub fn card(
  store: Memory,
  id: String,
  latest: fn(Ref) -> String,
) -> Result(#(Dossier, View(Refund)), decisions.Refusal) {
  memory.transaction(store, fn(tx) {
    use card <- result.try(decisions.open(
      first_point.desk(),
      tx,
      occurrence: id,
      by: clinic.felipe,
      latest:,
    ))
    use dossier <- result.try(
      view.context(
        decisions.shown(card),
        with: read_dossier(),
        content: recorded(tx),
      )
      |> result.map_error(fn(failure) {
        decisions.Unreadable(model.describe(failure))
      }),
    )
    Ok(#(dossier, view.of(card, content: recorded(tx))))
  })
}

// snips-end: same-context

/// The whole topic: the model reads Ana's balance, the balance changes,
/// and Felipe's card still shows what the model read, flagged as changed.
pub fn run() -> #(Dossier, List(view.Item)) {
  let store = memory.new()
  let assert Ok(Nil) =
    memory.transaction(store, fn(tx) {
      Ok(memory.put(
        tx,
        "message:m-ana-3",
        "Fui cobrada em atraso, mas paguei em dia.",
      ))
    })
  let context =
    Manifest(refs: [Ref("message", "m-ana-3", "1")], renderer: "refund-1")
  let assert Ok(recommendation) =
    model.run(
      billing_model(),
      context,
      live(store, fn() { Ok("overdue 80.00") }),
    )
  let assert Ok(waiting) =
    memory.transaction(store, decisions.recommend(
      first_point.desk(),
      _,
      decisions.proposal(
        trigger: Trigger(kind: "message", id: "m-ana-3"),
        about: clinic.ana,
        context:,
        recommending: recommendation,
      ),
    ))
  let assert occurrence.Awaiting(_) = waiting.status
  // The balance is paid after the model read it.
  let latest = fn(ref: Ref) {
    case ref.kind {
      "balance" -> model.digest("settled 0.00")
      _ -> ref.revision
    }
  }
  let assert Ok(#(dossier, document)) = card(store, waiting.id, latest)
  #(dossier, document.pulled)
}
