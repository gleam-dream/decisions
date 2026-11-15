// Must not compile: a correction that carries another point's output.
import decisions
import decisions/vocabulary.{Correct, Reason}
import decisions_usage/first_point
import gleam/option.{None}

pub type Invoice {
  Invoice(taker: String, cents: Int)
}

pub fn wrong_shape(tx, card) {
  decisions.decide(
    first_point.desk(),
    tx,
    card,
    Correct(output: Invoice("clinica-x", 80_000), reason: Reason("amount", None)),
  )
}
