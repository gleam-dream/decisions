// Control for decide_without_a_card and a_card_of_another_point.
import decisions.{type Card}
import decisions/memory.{type Memory}
import decisions/vocabulary.{Approve}
import decisions_usage/clinic.{type Refund}
import decisions_usage/first_point

pub fn approve(tx: Memory, card: Card(Refund)) {
  decisions.decide(first_point.desk(), tx, card, Approve)
}
