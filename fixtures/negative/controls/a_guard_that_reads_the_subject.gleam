// Control for a_guard_is_handed_no_output.
import decisions.{Gated}
import decisions/vocabulary.{type Subject}
import decisions_usage/clinic

pub fn guarded() {
  Gated(..clinic.refund_fee(), guard: fn(_tx, subject: Subject) {
    case subject.kind {
      "company" -> Ok([])
      _ -> Error(decisions.Refuse("refunds go to companies"))
    }
  })
}
