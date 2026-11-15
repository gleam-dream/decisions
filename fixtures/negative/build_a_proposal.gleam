// Must not compile: a proposal built as a record. Build one with
// `decisions.proposal`, so that fields added later break no caller.
import decisions

pub fn forge(trigger, subject, context, recommendation) {
  decisions.Proposal(
    trigger:,
    subject:,
    context:,
    recommendation:,
    parent: Error(Nil),
    requester: Error(Nil),
  )
}
