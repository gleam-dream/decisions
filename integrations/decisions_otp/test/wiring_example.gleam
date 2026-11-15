//// The wiring of an application on `decisions_otp`, compiled and run by
//// `wiring_example_test`. The repository README quotes the region
//// `otp-runtime`.

import decisions
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Ask, Policy}
import decisions/wire
import decisions_otp/runtime
import decisions_otp/store
import gleam/option.{Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/result

// snips-start: otp-runtime
/// The refund point, its gated tool, and what follows a settlement.
pub fn refund_desk() -> decisions.Desk(String, store.Tx) {
  decisions.desk(
    decisions.point("billing.fee_refund", wire.text()),
    drives: fn(_) {
      decisions.Gated(
        name: "refund",
        guard: fn(_, _) { Ok([]) },
        execute: fn(tx, released) {
          // The gated tool's write commits with the verdict that released it.
          store.add(tx, "refunds", decisions.output(released))
          Ok(Nil)
        },
      )
    },
    under: fn(_) {
      Ok(Policy(version: 1, rules: [], otherwise: Ask(AnyoneHolding("finance"))))
    },
    over: store.port(),
  )
}

/// What follows a settled refund: here, a row in the same transaction.
pub fn tell_the_customer(
  tx: store.Tx,
  refund: occurrence.Occurrence(String),
) -> Result(Nil, decisions.HandlerFailure) {
  store.add(tx, "outbox", "your refund " <> refund.id <> " is settled")
  Ok(Nil)
}

/// The application's tree: the store first, then the runtime that
/// delivers its wake-ups, settlements and triggers. `RestForOne`: if the
/// store's owner exits (losing everything), the runtime restarts with it
/// and takes a fresh handle.
pub fn start(
  name: store.Name,
  control: runtime.Control,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  supervisor.new(supervisor.RestForOne)
  |> supervisor.add(store.supervised(store.defaults(), named: name))
  |> supervisor.add(
    // Configured at each start, from the store's current handle.
    runtime.supervised_from(fn() {
      use s <- result.map(
        store.named(name) |> result.replace_error("the store is not running"),
      )
      runtime.Config(
        ..runtime.config(
          store.backlog(s),
          points: [runtime.point(refund_desk(), settled: tell_the_customer)],
          work: fn(_trigger) { Ok(Nil) },
        ),
        name: "refunds",
        control: Some(control),
      )
    }),
  )
  |> supervisor.start
}
// snips-end: otp-runtime
