// Must not compile: a verdict given on an occurrence id, with no card
// ever opened.
import decisions
import decisions/vocabulary.{Approve}
import decisions_usage/first_point

pub fn rubber_stamp(tx) {
  decisions.decide(first_point.desk(), tx, "occ-1", Approve)
}
