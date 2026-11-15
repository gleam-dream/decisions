// Must not compile: a card of a point whose output is a text, decided at
// the refund point. This proves only that another output type is refused.
// Two points with one output type are told apart at run time: a desk
// refuses another point's occurrence with `UnknownOccurrence`.
import decisions.{type Card, type Desk}
import decisions/memory.{type Memory}
import decisions/vocabulary.{Approve}
import decisions_usage/clinic.{type Refund}

pub fn elsewhere(desk: Desk(Refund, Memory), tx: Memory, card: Card(String)) {
  decisions.decide(desk, tx, card, Approve)
}
