//// What a process can subscribe to in `decisions_otp/store`, and what it
//// is told. A subscriber is told **after a commit** that something it
//// watches changed, and never for a transaction that rolled back.
////
//// These are the topics of `decisions_otp/store`. `decisions_postgres`
//// offers a different shape (everything, a point or an occurrence, with no
//// `Missed`); see its README.
////
//// A hint is a reason to read again, not a durable event. The record in
//// the store is the truth: a subscriber that misses a hint, or that starts
//// listening late, loses nothing as long as it reads the record. When the
//// store has to drop hints for a subscriber that is not keeping up, its
//// next hint is preceded by `Missed(count)`, so it knows to read
//// everything it watches again. When no further change comes, the store
//// sends `Missed(count)` by itself as soon as the subscriber's mailbox
//// has room again (it looks every 20 ms while any subscriber is behind).
////
//// ```gleam
//// import decisions_otp/live
//// import decisions_otp/store
////
//// let hints = process.new_subject()
//// let subscription = store.subscribe(s, live.ToOccurrence("refund-1"), hints)
//// case process.receive(hints, 5000) {
////   Ok(live.Changed(occurrence:, status:, ..)) -> reread(occurrence)
////   Ok(live.Missed(_)) -> reread_everything()
////   Error(Nil) -> Nil
//// }
//// store.unsubscribe(s, subscription)
//// ```

/// What a subscriber watches.
pub type Topic {
  /// One occurrence, by id.
  ToOccurrence(id: String)
  /// Every occurrence of a decision point, by the point's name.
  ToPoint(name: String)
  /// The queue of a decision set: an occurrence that enters or leaves the
  /// set's queue.
  ToQueue(set: String)
  /// The review queue of a decision point, by the point's name: an
  /// occurrence sampled for a review that enters or leaves it.
  ToReviews(point: String)
}

/// What a subscriber is told.
pub type Hint {
  /// A committed transaction changed this occurrence. `status` is the
  /// status name of its head after the commit. Read the record for more.
  Changed(point: String, occurrence: String, status: String)
  /// The subscriber was not keeping up and `count` hints were dropped
  /// before this one. Read again everything the subscription watches.
  Missed(count: Int)
}
