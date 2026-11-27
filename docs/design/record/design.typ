#import "../.render/designlib.typ": *

#let title = [Record]
#let accent = "violet"
#let body = [
#section(title: "Foundation", lead: "The record context owns what a decision point is, how an occurrence moves, and what its record holds.", body: [
  #goal(title: "Every kind of recommender produces the same record")[A rule, a cascade, one model call, an agent loop and a person acting on their own authority each produce one recommendation of the same shape. They differ only in their explanation, so one point can climb from no model to a sampled model and back by publishing policy versions.]
  #goal(title: "A person sees what the model had")[The card shows the context the model started from and the reads it received, with their content as read and a mark on each input that has changed since. One reader function builds the model's typed context and the card's.]
  #no-goal(title: "A condition for proceeding inside the declaration")[A `Point` holds no rule for proceeding without a person. Every such rule is policy data, so a threshold has one home and changing it is a write.]
  #invariant(title: "Where an occurrence stands is a fold of its record", enforcement: "mechanism")[`occurrence.fold` and `occurrence.apply` compute the status from the entries alone. An entry that is illegal from the current status leaves the status unchanged.]
  #invariant(title: "Only the executor receives a released output", enforcement: "mechanism")[A guard receives the transaction and the subject; the release check receives a `ToRelease` value that no executor accepts; only the executor receives the opaque `Released` value, built for one release attempt inside the savepoint. The fixture `a_release_check_value_to_an_executor` fails to compile.]
  #invariant(title: "A verdict needs a recorded showing of the standing output", enforcement: "mechanism")[`decide` takes a card, which only `open` and `resume` construct. It refuses a card that names no recorded showing to its holder and a card shown before someone else corrected the output.]
  #invariant(title: "A policy reads only declared facts", enforcement: "mechanism")[The desk refuses to apply a policy that fails `publishable`. A policy written in Gleam with typed fact keys does not compile with a misspelt fact or a number rule on a text fact.]
  #invariant(title: "A bundle's members agree on its size and never exceed it", enforcement: "partial")[The desk refuses a member whose size differs from a recorded member's, or one beyond the size (#adr(58)). Two members admitted concurrently can still exceed it, and then `is_complete` never holds; invariant I9 of `decisions/testing` reports it.]
  #principle(title: "Keep everything on the record, including what failed")[A failed model attempt and a verdict whose release was refused and rolled back are each appended in a transaction of their own, so the record shows them although the transaction they happened in left nothing.]
  #principle(title: "Refuse with a type, never with text")[Every refusal is a variant of `decisions.Refusal`, every model failure a variant of `model.Failure`. A caller decides on a retry or a message from the variant.]
])

#pending-ledger(
  pending-entry(title: "Blind verdicts", kind: "build", since: "2026-11-15", adr: [#adr(15)])[
    A policy outcome that asks for a verdict formed before the recommendation is shown, and the verbs that give it: `AskBlind`, `open_blind`, `decide_blind` and `review_blind`. Agreement is then computed from the two outputs and the record says the verdict was blind. The types leave room: `Outcome`, `Eligible` and `Refusal` are documented as growing in a minor release.
  ],
  pending-entry(title: "Shadow recommendations", kind: "build", since: "2026-11-15", adr: [#adr(15)])[
    `shadow` records a second recommender's output on the same context, never acted on and tallied against the same verdicts, for a champion and a challenger.
  ],
  pending-entry(title: "Links between occurrences", kind: "build", since: "2026-11-15", adr: [#adr(15)])[
    A link on a proposal that names an earlier occurrence, so a reversal is a new occurrence at a reversal point and "what did this decision lead to" is answerable from records. Today `key` and `parent` are the only hooks.
  ],
  pending-entry(title: "Generic clients", kind: "build", since: "2026-11-15", adr: [#adr(15)])[
    A value that erases a point's output type behind closures, so that one queue, one MCP server or one page can hold cards of many points. The output's JSON Schema is already on the card document.
  ],
  pending-entry(title: "A consulted point that settles without an output", kind: "ruling", since: "2026-11-14", adr: [#adr(20)])[
    A consulted point that is rejected or expires never calls `inform`, so the consulting occurrence waits until its deadline, or forever without one. `inform` with no facts is accepted and lets the policy fall to its default; nothing calls it automatically.
  ],
  pending-entry(title: "One from finance and one from legal", kind: "ruling", since: "2026-11-14")[
    `Several(count, of)` counts different validators under one eligibility, and `Either` accepts when any one alternative is met. Requiring approvals from two different sets at once needs an `All` eligibility. The owner decided to add it when the first real point needs it; approvals already record the sets their validator held, so it is a small addition. Until then it is not built.
  ],
  pending-entry(title: "Moving an occurrence's deadline later", kind: "ruling", since: "2026-11-17", adr: [#adr(54)])[
    dash-crm may need a verb that moves an occurrence's deadline later, when a draft survives a newer customer message and the service window reopens. It would append an entry of its own to a record not begun or an undecided occurrence, carrying the whole new deadline computed when it is written (the point's validity is code and may change, so the fold cannot recompute it), and it would be refused once the record has lapsed by the store clock. It is built when dash-crm rules on concurrent drafts.
  ],
  pending-entry(title: "Admission order for points that only expect", kind: "ruling", since: "2026-11-16")[
    `happened` takes a lock per point and subject, so two `happened` calls about one subject run one after the other. A point whose triggers are admitted with `expect` alone, with no `happened`, has no such order between two expectations about one subject. Whether that matters is a question for the first application that needs it.
  ],
  pending-entry(title: "A policy condition cannot read who recommended", kind: "ruling", since: "2026-11-15")[
    A condition reads the recommender only through `OwnAct`. A rule such as "proceed when classifier v5 is sure" cannot name the recommender or its version; an application reports it as a signal instead.
  ],
  pending-entry(title: "A policy per tenant", kind: "ruling", since: "2026-11-14")[
    A tenant can be a declared fact that rules read today. Whether a tenant instead gets its own policy, read by the desk's policy function, is open.
  ],
  pending-entry(title: "Replaying a provider call under a changed prompt", kind: "ruling", since: "2026-11-14")[
    The record answers only the request that was made. A candidate with another prompt is unanswered (`NotRecorded`); scoring it needs a live call, which is no longer a replay.
  ],
  pending-entry(title: "A failed attempt has no identity", kind: "ruling", since: "2026-11-15")[
    `record_failure` records one attempt per call. Two attempts that failed alike look the same, so the desk cannot tell a second attempt from a repeated call. After an `Unavailable` outcome a caller reads the record (`NotRecommended(attempts)`) before calling again. Whether an attempt should carry an identity is open.
  ],
  pending-entry(title: "Codec evolution", kind: "ruling", since: "2026-11-14")[
    An entry that no longer decodes with its point's codec makes its record unreadable; the record is contained and set aside, not migrated. Entries carry no codec version.
  ],
  pending-entry(title: "The export's destination", kind: "ruling", since: "2026-11-14")[
    The `decision-example.v1` document exists. The lake it is appended to, its versioning and its pseudonymisation do not.
  ],
  pending-entry(title: "Whether hermeticity is enforced", kind: "ruling", since: "2026-11-14")[
    A model that performs its own I/O instead of reading through its sources is not stopped. The library hands out only the recorded path.
  ],
)

#section(title: "The model at a glance", lead: "A point declares; a desk binds it; an occurrence is the record the desk appends to.", visual: diagram(
  altitude: "L2", viewpoint: "domain-model", title: "The record's concepts and their cardinalities",
  nodes: (
    (id: "point", label: "Point", sub: "declaration", kind: "value-object", tint: "violet"),
    (id: "policy", label: "Policy", sub: "versioned data", kind: "value-object", tint: "violet"),
    (id: "desk", label: "Desk", sub: "point + tool + policy + port", kind: "component", tint: "violet"),
    (id: "occ", label: "Occurrence", sub: "folded from its record", kind: "aggregate", tint: "violet"),
    (id: "entry", label: "Entry", sub: "eighteen kinds", kind: "event", tint: "violet"),
    (id: "card", label: "Card", sub: "one showing", kind: "value-object", tint: "violet"),
    (id: "tool", label: "Gated tool", sub: "guard + executor", kind: "component", tint: "violet"),
  ), edges: (
    (from: "desk", to: "point", relation: "dependency", label: "one point"),
    (from: "desk", to: "policy", relation: "call", label: "reads the current version"),
    (from: "desk", to: "tool", relation: "call", label: "releases to"),
    (from: "point", to: "occ", relation: "dependency", label: "one → many"),
    (from: "occ", to: "entry", relation: "dependency", label: "one → one or more"),
    (from: "occ", to: "card", relation: "dataflow", label: "shown as"),
  ), caption: [A desk holds no state and is built wherever it is needed. An occurrence's identity is its id; everything else about it is computed from its entries. The shape is recorded in #adr(1) and #adr(2).],
), body: [
  #entity(id: "point", title: "Point", description: [The declaration of a decision point. It is built once at wiring and stored nowhere but its name.], kind: "value-object", owner: "decisions", lifecycle: "immutable", domain: "record", tint: "violet")[
    #attribute(name: "Name", type: "Stable text", provenance: "authored")[Written on every occurrence's first entry. A desk refuses an occurrence of another point with `UnknownOccurrence`.]
    #attribute(name: "Output codec", type: "Codec of the output type", provenance: "authored")[The only translation between the output and stored text. Built from a json_blueprint codec it also carries the output's JSON Schema. A point is copied with every desk sent to a process or captured by a job, so a point's codec copies about as much as the json_blueprint codec it was built from (#adr(57)).]
    #attribute(name: "Allowed verdicts", type: "Approve or reject, or approve, reject or correct", provenance: "authored")[Approve and reject by default. A correction on a point that allows none is `VerdictNotAllowed`.]
    #attribute(name: "Declared facts", type: "Facts of the output and signals, each with its type", provenance: "authored")[What a policy may read besides the recommender and the time waited.]
    #attribute(name: "Hold", type: "Optional duration", provenance: "authored")[A wait between every acceptance and its release (`with_hold`).]
    #attribute(name: "Hold in the policy", type: "Optional duration on `Proceed`", provenance: "authored")[A policy outcome `Proceed(sample:, hold:)` may carry its own hold, an undo window on what the policy accepted by itself. When it does, that hold is used; otherwise the point's `with_hold`. A new policy version changes the window for new acceptances, not for an occurrence already held (#adr(48)).]
    #attribute(name: "Withdrawers", type: "Optional decision set", provenance: "authored")[Holders of this set may withdraw a held occurrence besides its decider (`withdrawn_by`).]
    #attribute(name: "Validity", type: "Optional duration", provenance: "authored")[How long an occurrence may wait to be decided.]
    #attribute(name: "Superseding events", type: "Event names", provenance: "authored")[World events that expire an undecided occurrence about the same subject.]
    #attribute(name: "Reviewers", type: "Optional decision set", provenance: "authored")[Who may review a sampled occurrence.]
  ]
  #entity(id: "occurrence", title: "Occurrence", description: [One recommendation about one subject and everything that happened to it. The aggregate whose invariants every verb holds under the occurrence's lock.], kind: "aggregate", owner: "decisions desk", lifecycle: "stateful", domain: "record", tint: "violet")[
    #attribute(name: "Id", type: "Admission key or a new id", provenance: "derived")[With `recommend_once` the key is the id; keys are one namespace across every point of a store.]
    #attribute(name: "Entries", type: "Ordered entries numbered from 1", provenance: "observed")[The record. Failed attempts may come first; the recommendation follows them.]
    #attribute(name: "Trigger, subject, requester, parent, context", type: "Fixed by the recommendation entry", provenance: "derived")[Read from the first non-attempt entry.]
    #attribute(name: "Recommendation", type: "Output, recommender, explanation, signals, reads", provenance: "observed")[What the recommender proposed, never changed.]
    #attribute(name: "Deadline", type: "Optional time", provenance: "derived")[The effective deadline: the earliest of the recommendation's time plus the point's validity, the deadline the expectation carried, and the deadline the proposal carried. Fixed on the recommendation entry; a recommendation never moves it later (#adr(54)).]
    #attribute(name: "Informed facts", type: "Facts", provenance: "observed")[What consulted points returned.]
    #attribute(name: "Policy version and steps", type: "Version and the remaining timeline", provenance: "derived")[From the latest `policy_applied` entry.]
    #attribute(name: "Sampled", type: "Flag", provenance: "derived")[Set once any applied answer sampled it; it never clears.]
    #attribute(id: "status", name: "Status", type: "Status", provenance: "derived", state-type: "status", state-machine: "lifecycle")[Folded from the entries.]
    #relates(cardinality: "n : 1")[Belongs to one point.]
    #relates(cardinality: "1 : 0..n")[Has showings, verdicts, reviews, effect reports and assessments.]
  ]
])

#section(title: "Admission", lead: "A recommendation enters the record once per key, and the policy answers it in the same transaction.", body: [
  #points(
    [A recommender builds a proposal with `decisions.proposal(trigger:, about:, context:, recommending:)`, and adds `asked_by` when a person asked, `hanging_from` when the occurrence follows a run or another occurrence, `in_bundle` when it is one of several occurrences proposed together, and `valid_until(at:)` when the occurrence has a deadline of its own, an instant the application knows, such as the end of a service window. A recommendation by `Person(subject)` makes that person the requester without `asked_by`.],
    [`recommend` admits the proposal under a new id from the port. `recommend_once(key:)` admits it under `key` at most once: it loads the key, which locks it even though nothing exists yet, and returns the occurrence already there when one is, writing nothing. A key held by another point's occurrence is refused with `KeyTaken(point)`. Applications prefix keys with something the point owns.],
    [The recommendation entry fixes the effective deadline. When the occurrence's own deadline (its expectation's or its proposal's) has already passed by the store clock, the occurrence is recorded and expires at once as deadline passed: no policy runs and nothing is shown or released, and the verb returns the expired occurrence. On a lapsed record not begun whose expiry is not yet written, the expiry is written first and the recommendation after it, so a lapsed record has one shape whichever came first. The settlement notice is admitted by whichever write ended the record; a recommendation after an expiry admits none (#adr(54)). Otherwise the desk then reads the current policy through the desk's policy function, refuses with `NoPolicy` when it cannot be read and with `Unpublishable` when it reads an undeclared fact, evaluates it over the recommender and the facts, and records the answer with its version in a `policy_applied` entry.],
    [A model that failed before anything was recommended is recorded with `record_failure(key:, trigger:, about:, failure:)` in a transaction of its own. It appends an `attempt_failed` entry, writes a head with status `pending`, and returns every failed attempt so far. Each call records one attempt, so after an `Unavailable` outcome the caller reads the record before calling again. Once the key holds a recommendation it writes nothing. A later `recommend_once` on the key keeps the attempts at the start of the record; any other verb on such a key is refused with `NotRecommended(attempts)`, and `decisions.read_record` returns `NotBegun` for it. `record_failure_with(.., evidence:)` also points at evidence the application stored about the attempt, such as a provider exchange that did not decode; a model can carry the same references in its failure (`model.with_evidence`, `Failure.WithEvidence`), and `record_failure` stores them on the attempt. Give `record_failure` the key `recommend_once` will use for the same trigger, so attempts and recommendation share one record.],
    [`expect(desk, tx, key:, trigger:, about:)`, called in the transaction that receives a trigger, records that a recommendation is expected under the key: an `expected` entry, and a head with status `pending`. From then on `happened` for a newer event about the subject supersedes the record before it begins, and the `recommend_once` or `record_failure` that follows for the key is refused with `SupersededBefore(event)` and writes nothing. `expect` is safe to repeat; on a key that already holds a recommendation it does nothing (#adr(50)). An expectation made with `expect` has no deadline: a record that stays expected keeps status `pending` and its arrival time.],
    [`expect_until(.., valid_until:)` gives the expectation a deadline of its own, rounded down to whole milliseconds and written on the `expected` entry. The record not begun is then due at it: its head's due time is the deadline, and every write to the record compares `occurrence.pending_wake_times` before and after and schedules when they differ, so one wake-up is pending while it waits and none once it ended. A repeated expectation with an earlier deadline appends another `expected` entry and the earliest counts; one with an equal or later deadline, or none, writes nothing. On a key that already holds a recommendation it does nothing. At or after the deadline by the store clock the record is lapsed: the wake-up appends `expired` as deadline passed, its head's status becomes `expired`, it is settled and admits one settlement notice. An expectation whose deadline has already passed is written with its expiry at once. `expect`, `expect_until`, `record_failure`, `record_failure_with`, `read` and every verb that needs an occurrence are then refused with `DeadlinePassedBefore(deadline)` and write nothing; `read_record` returns `NotBegun`, with the cause in `ended`. A recommendation that follows is recorded and expires at once (#adr(54)).],
    [The subject lock: for an event the point declares, `happened` first loads `subject_lock(point:, subject:)` through the port, which locks that id for the rest of the transaction, and only then reads which records wait. Two `happened` calls about one subject of one point therefore run one after the other, and the second sees every record the first committed, including the key its transaction expected, so two triggers about one subject admitted at the same moment cannot both miss each other. The id is `subject_lock_prefix` (`decisions.subject-lock:`, reserved) followed by the lowercase hex SHA-256 of the point, the subject's kind and its id, 87 bytes in all; no entry is stored under it. A transaction that calls only `expect`, `recommend` or `recommend_once` takes no subject lock. Locks are taken in one order, the subject lock and then the records in `waiting`'s order, so a transaction that also expects a key calls `happened` before `expect`: the other order could deadlock with a later transaction and would supersede the key just expected. A key that was not expected first is still open to the superseding window.],
  )
  #behavior(title: "A trigger delivered again finds its occurrence", area: "Admission", level: "boundary")[
    #given[An occurrence was admitted under a key.]
    #when[The same trigger is delivered again, at once or later, with the same key.]
    #then[The existing occurrence is returned and nothing is written.]
    #then[Concurrent deliveries of one key admit one occurrence.]
  ]
])

#section(title: "Bundles", lead: "Several occurrences proposed together stay ordinary occurrences, and whoever follows them starts what comes after once.", body: [
  #points(
    [One recommendation that proposes several separable items, such as the lines of an expense report or a reply and a process to start, is admitted as one occurrence per item. `in_bundle(proposal, Bundle(key:, size:))` names the bundle each belongs to and how many occurrences it holds; `recommend_bundle(desk, tx, bundle:, items:)` admits every item of one point under its own key, with the size the number of items. A bundle may span points. Each member is judged, held, released, reported and assessed on its own, under its point's policy and its own release key, and the record carries the bundle on the `recommended` entry and on the head (#adr(58)).],
    [The desk refuses a member with `BadBundle(bundle, fault)`, disposition `Poisoned`, when the key is empty (`NoBundleKey`), the size is below one (`EmptyBundle`), a member already recorded another size (`SizeDiffers(recorded)`), or the bundle already holds as many members as its size (`BundleFull`). A member delivered again is found by its key, as any trigger is.],
    [`members(desk, tx, bundle:)` reads the bundle's members of every point, in ascending id order, as their heads stand, without a lock. `is_complete(members)` holds when the bundle has as many members as every member says it holds and every one has settled.],
    [What follows a bundle is the follower's: on each settlement notice it reads the members and, once the bundle is complete, recommends the follow-on with `recommend_once` under a key derived from the bundle. A follower runs after the settlement it is told of committed, so the follower of the member that committed last sees the bundle complete; `recommend_once` turns every other follower that sees it complete into nothing. The library keeps no "ended" fact and no lock for a bundle.],
    [Rejecting the whole proposal is a verdict on each member by a validator each member admits; all or nothing across members is the caller's transaction, as for any group of occurrences.],
  )
  #behavior(title: "Each bundle starts what follows it once", area: "Bundles", level: "boundary")[
    #given[A bundle of five members at one point, admitted in one transaction, whose point's follower recommends the follow-on under a key derived from the bundle once the bundle is complete.]
    #when[Every member is decided at once, from its own process, some approved and some rejected.]
    #then[Each approved member is released once; each rejected one releases nothing.]
    #then[Exactly one follow-on is recommended for the bundle, never none and never two.]
  ]
  #behavior(title: "A bundle is complete only once every member arrived", area: "Bundles", level: "boundary")[
    #given[A bundle whose members were admitted in more than one transaction.]
    #when[Every member admitted so far has settled, and not every member has arrived.]
    #then[The bundle is not complete, and nothing follows it yet.]
  ]
])

#section(title: "The lifecycle", lead: "Nine statuses, eighteen entry kinds, and one fold that applies them.", body: [
  #state-type(id: "status", title: "Status", variants: (
    (id: "recommended", description: [Recorded and waiting for the policy, or for a consulted point when the status names one.]),
    (id: "awaiting", description: [Waiting for verdicts from whoever an eligibility admits.]),
    (id: "accepted", description: [Accepted and not yet held or released. No verb ends here.]),
    (id: "held", description: [Accepted and waiting until the hold ends before release.]),
    (id: "released", description: [The final output reached its gated tool under the release key. Settled.]),
    (id: "rejected", description: [A validator rejected it with a reason. Settled.]),
    (id: "expired", description: [Its deadline passed or an event superseded it. Settled.]),
    (id: "withdrawn", description: [The decider took the held output back. Settled.]),
    (id: "refused", description: [The guard or the gated tool refused a release nobody waited on. Settled.]),
  ))
  #state-machine(id: "lifecycle", subject: "occurrence", state-field: "status", state-type: "status", title: "The occurrence lifecycle", flow: "top-to-bottom", initial: "recommended", accepting: ("released", "rejected", "expired", "withdrawn", "refused"), states: ("recommended", "awaiting", "accepted", "held", "released", "rejected", "expired", "withdrawn", "refused"), transitions: (
    ("recommended", "accepted", "policy proceeds"),
    ("recommended", "awaiting", "policy asks"),
    ("recommended", "recommended", "policy consults / answer informs"),
    ("recommended", "expired", "deadline / superseded"),
    ("awaiting", "awaiting", "approval short of the count / step asks"),
    ("awaiting", "accepted", "enough approvals / step proceeds"),
    ("awaiting", "recommended", "step consults"),
    ("awaiting", "rejected", "reject"),
    ("awaiting", "expired", "deadline / superseded"),
    ("accepted", "held", "a hold applies"),
    ("accepted", "released", "guard and tool allow"),
    ("accepted", "refused", "refusal, nobody waiting"),
    ("held", "released", "hold ends; guard and tool allow"),
    ("held", "refused", "hold ends; refusal"),
    ("held", "withdrawn", "decider or withdrawer, before the end"),
    ("held", "expired", "superseded"),
    ("released", "released", "review / effect report"),
  ), caption: [Accepted lasts only inside a verb: the same transaction holds or releases the output. When a verdict completes the acceptance and the guard or the tool refuses, the verb fails with `ToolRefused` and its transaction rolls back, so the occurrence still awaits; no transition happens. An assessment can be appended to every settled status and changes none.])
  #subsection(title: "Transitions")[
    #md-table(4, (
      [*From*], [*Trigger and guard*], [*To*], [*Entries appended*],
      [nothing], [`recommend` or `recommend_once`, the policy readable and publishable], [recommended, then as the policy says], [`recommended`, `policy_applied`],
      [recommended], [The policy proceeds], [accepted, then held (the outcome's hold or the point's `with_hold` applies), or released, or refused], [`held`; or `released`; or `refused`],
      [recommended], [The policy asks], [awaiting], [none beyond `policy_applied`, which carries the remaining steps],
      [recommended], [The policy consults a point it has not consulted on this occurrence], [recommended, consulting it], [`policy_applied`; then the consult handler runs in the same transaction],
      [recommended, consulting P], [`inform(from: P)` with declared facts, before the deadline], [as the policy current now says], [`informed`, `policy_applied`],
      [awaiting], [`decide` with an approval or correction after which the eligibility is met], [accepted, then held (a hold applies) or released], [`decided` with the sets its validator held, then `held` or `released`],
      [awaiting], [`decide` with an approval after which no alternative is met], [awaiting], [`decided`],
      [awaiting], [`decide` with a rejection carrying a reason], [rejected], [`decided`],
      [awaiting], [`wake` when a step is due, before the deadline], [as the step says], [`policy_applied`, and what the outcome requires],
      [recommended or awaiting], [`wake` at or after the deadline], [expired, deadline passed], [`expired`],
      [nothing], [`expect`, `expect_until`, or `record_failure` before any recommendation], [not begun; head status `pending`, due at the expectation's deadline when it has one], [`expected`, or `attempt_failed`],
      [nothing or not begun], [`expect_until` with a deadline already passed], [lapsed before it began; one settlement notice], [`expected`, `expired`],
      [not begun, with a deadline], [`wake` at or after the deadline], [lapsed before it began, head status `expired`; one settlement notice; `expect`, `expect_until`, `record_failure`, `read` and every verb that needs an occurrence are then refused with `DeadlinePassedBefore`], [`expired`],
      [nothing, or not begun before its own deadline], [`recommend` or `recommend_once` with a proposal deadline already passed], [expired, deadline passed; no policy runs; one settlement notice], [`recommended`, `expired`],
      [not begun or lapsed before it began, its deadline passed], [`recommend_once`], [expired, deadline passed; no policy runs; a settlement notice only when this write ends the record], [`expired` unless the record already holds it, then `recommended`],
      [not begun], [`happened` with a declared event about the subject], [superseded before it began, or deadline passed when its own deadline had passed; its wake-up is cancelled; `recommend_once` is then refused with `SupersededBefore`, or recorded expired after a deadline], [`expired`],
      [held], [`happened` with a declared event about the subject], [expired, superseded; the hold's wake-up is cancelled and nothing is released], [`expired`],
      [recommended or awaiting], [`happened` with a declared event about the subject], [expired, superseded; or deadline passed when already lapsed], [`expired`],
      [held], [`wake` at or after the hold's end], [released, or refused when the guard or the tool refuses], [`released` or `refused`],
      [held], [`withdraw` by the decider, or `withdraw_as` by the decider or a withdrawer, before the hold's end], [withdrawn], [`withdrawn`],
      [released], [`report`], [released], [`effected`],
      [released and sampled], [`open` and `review` by an eligible reviewer], [released], [`opened`, `reviewed`],
      [any settled status], [`assess`], [unchanged], [`assessed`],
    ))
  ]
  #subsection(title: "Entry kinds")[
    #md-table(3, (
      [*Kind*], [*Appended by*], [*What it means*],
      [`expected`], [`expect`, `expect_until`], [A recommendation is expected under the key, about the subject, with the occurrence's own deadline when it has one; again only for an earlier deadline. Only before `recommended`.],
      [`attempt_failed`], [`record_failure`, `record_failure_with`], [A model failed under the key before any recommendation, with any evidence the application stored. Only before `recommended`.],
      [`recommended`], [`recommend`, `recommend_once`], [The recommendation, with point, trigger, parent, subject, requester, context and #term("term-effective-deadline"). It may follow an `expired` entry whose cause is deadline passed, and the occurrence then starts expired.],
      [`informed`], [`inform`], [A consulted point's answer as facts.],
      [`policy_applied`], [admission, `inform`, `wake`], [The outcome, the version that gave it, whether it sampled, and the later steps.],
      [`opened`], [`open`], [A showing to a validator, with each drifted input.],
      [`expanded`], [`expand`], [What a validator opened beyond the card, as evidence.],
      [`noted`], [`note`], [What a validator brought from outside the card.],
      [`decided`], [`decide`], [A verdict, with the showing it was given on and the decision sets its validator held.],
      [`verdict_refused`], [`record_refusal`], [A verdict whose release was refused and rolled back. It changes no status.],
      [`reviewed`], [`review`], [A verdict after release on a sampled occurrence.],
      [`held`], [the desk on acceptance], [The hold's end.],
      [`withdrawn`], [`withdraw`], [The decider took the held output back.],
      [`released`], [the desk on release], [The release key, the gated tool's name and the evidence its guard and release check relied on.],
      [`effected`], [`report`], [What the release did outside the database.],
      [`refused`], [the desk on release], [A refusal by the guard, the release check or the tool with nobody waiting.],
      [`expired`], [`wake`, `happened`], [Deadline passed, or superseded by a named event; also on a held occurrence or a record not yet begun, which a wake-up expires at its own deadline.],
      [`assessed`], [`assess`], [What proved true later.],
    ))
    #points([`decisions/entry.kinds` lists the eighteen kind names in this order, for a store's column constraint. `Event`, `Status`, `Refusal`, `Outcome` and `Eligible` may gain variants in a minor release, so code that matches them keeps a catch-all branch.])
  ]
  #subsection(title: "Refusals and their dispositions")[
    #points([`decisions.disposition(refusal)` classifies every refusal by one of four meanings, so a caller or a runtime decides what to do without reading text (#adr(21), #adr(39)). `Transient` is contention or a store whose outcome is unknown: deliver again soon, uncounted. `Retry` may pass on another try or may never pass: deliver again after a backoff, counted, and set aside when the attempts are used. `Poisoned` needs an operator while the occurrence still waits for what the job was delivering: set the job aside, never drop it. `Final` means the occurrence moved on or the job can never apply to it: the job is done. Every variant is named in the classification, so a new one cannot be classified by accident.])
    #md-table(4, (
      [*Refusal*], [*Returned when*], [*Disposition*], [*What the caller does*],
      [`UnknownOccurrence`], [No occurrence of this desk's point has the id; the id belongs to another point.], [Final], [Check the id and the desk.],
      [`NotRecommended(attempts)`], [The key holds only failed attempts.], [Final], [Decide on a retry from the attempts' failures.],
      [`SupersededBefore(event)`], [`recommend_once`, `record_failure`, `expect` or a read on a key a newer event superseded before it began.], [Final], [Drop the trigger: its work is moot.],
      [`DeadlinePassedBefore(deadline)`], [`expect`, `expect_until`, `record_failure`, `record_failure_with`, `read` or a verb that needs an occurrence, on a key whose own deadline passed by the store clock before it began. Never from `recommend_once`, which records a late recommendation expired.], [Final], [Drop the trigger: nothing can be decided any more.],
      [`NotAwaiting`], [The occurrence is not waiting for this: it settled without a verdict, it lapsed, or it waits for a consulted point.], [Final], [Read it; nothing can be decided.],
      [`AlreadyDecided(by)`], [A verdict settled it; also `open` on such an occurrence.], [Final], [Tell the validator who decided.],
      [`NotEligible`], [`decide`, `open` or `resume` by a validator no alternative admits: holding no set it waits for, the requester or own-act recommender under someone-else eligibility, or one who already approved the standing output; or a review by someone who may not review.], [Final], [Show the card to someone else.],
      [`VerdictNotAllowed`], [A correction on a point that allows none.], [Final], [Approve or reject.],
      [`ReasonRequired`], [A rejection or correction with an empty reason category.], [Final], [Supply a category.],
      [`NoteRequired`], [The reason is missing context and the validator wrote no note.], [Final], [Note what was missing, then decide.],
      [`NeverShown`], [The card or ticket names no recorded showing to its holder.], [Final], [Open the card.],
      [`OutputChanged`], [Someone else corrected the output after this card was shown.], [Final], [Open the card again.],
      [`NotHeld`], [`withdraw` on an occurrence not on hold, or after the hold ended by the store clock.], [Final], [Nothing can be withdrawn.],
      [`NotTheDecider`], [`withdraw` by someone other than the decider, or `withdraw_as` by someone who is neither the decider nor a withdrawer.], [Final], [Ask the decider or a withdrawer.],
      [`NotReleased`], [`report` before a release.], [Final], [Nothing outside can have happened.],
      [`NotSampled`], [`review` on an occurrence not sampled or not released; `open` on one the policy released unsampled.], [Final], [Nothing to review.],
      [`NotSettled`], [`assess` on an occurrence that has not settled.], [Final], [Assess after it settles.],
      [`NotConsulting`], [`inform` when the occurrence does not wait for that point.], [Final], [Drop the answer.],
      [`ToolRefused(reason, rollback)`], [The guard, the release check or the gated tool answered `Refuse` in the verdict's transaction.], [Final], [Roll back, then pass the rollback token to `record_refusal` in a new transaction.],
      [`ToolUnsure(reason)`], [The guard, the release check or the gated tool answered `Unsure`: it could not tell. Nothing is recorded as refused.], [Retry], [Roll back and try again later.],
      [`ConsultFailed(point, reason)`], [The consult handler failed to ask the point.], [Retry], [Roll back and try again later; a handler that is never wired is set aside when the attempts are used.],
      [`NoPolicy(reason)`], [The policy could not be read.], [Retry], [Roll back and try again later.],
      [`InvalidFacts(faults)`], [An answer with an undeclared fact or a fact of the wrong type.], [Poisoned], [An operator fixes the consulted point's answer.],
      [`KeyTaken(point)`], [A key held by an occurrence of another point.], [Poisoned], [An operator fixes the key.],
      [`Unpublishable(faults)`], [The policy read fails `publishable`.], [Poisoned], [An operator publishes a corrected version.],
      [`Unreadable(reason)`], [The record does not decode with the point's codec.], [Poisoned], [An operator sets the record aside.],
      [`Unencodable(reason)`], [The codec cannot encode an output to store.], [Poisoned], [An operator fixes the codec.],
      [`StoreFailed(error)`], [The store answered `Contended` or `Unavailable`; or `Conflict`.], [Transient; Retry for `Conflict`], [Roll back; after `Unavailable`, read the record before running the call again; a conflict that repeats is a second writer.],
    ))
  ]
  #subsection(title: "The account of an occurrence")[
    #points(
      [`occurrence.account(occurrence)` says what really happened, as a follower or an agent tells someone, and never a status in between: `Undecided` while it waits or is held and can still be withdrawn; `Done(final, key, effect)` once released, with its release key, with the latest effect report, or none while nothing is known or the latest is uncertain; `TurnedDown(by, reason)`; `Lapsed(cause)`; `TakenBack(by)`; `Blocked(reason)` when the guard, the check or the tool refused.],
      [`occurrence.decided_by(occurrence)` names who answers for the outcome: `ThePolicy(version)` or `APerson(subject)`, the validator who accepted, rejected or withdrew it, also for an output the tool later refused. It is `None` while the occurrence waits and when it expired, since nobody decided.],
    )
  ]
  #subsection(title: "What is safe to repeat")[
    #md-table(2, (
      [*Verb*], [*Repeated*],
      [`recommend_once`], [Returns the same occurrence and writes nothing.],
      [`decide`], [The same verdict on the same card or ticket returns the occurrence and runs nothing, once it has moved on or while that approval still counts. A newly opened card is a new showing.],
      [`wake`], [Writes nothing when nothing is due; returns `NotDue(until)` with a future time or `NothingDue`.],
      [`happened`], [Supersedes only what has released nothing and has not been superseded, so a repeated event finds nothing more.],
      [`expect`, `expect_until`], [Records the expectation once; again only for an earlier deadline; on a key that already holds a recommendation it does nothing.],
      [`inform`], [A second answer from the same point is `NotConsulting`.],
      [`withdraw`, `review`], [A second call is `NotHeld` or `NotEligible`.],
      [`resume`, `read`], [Write nothing.],
      [`open`], [Records a new showing each time.],
      [`report`, `assess`, `note`, `expand`], [Append again each time; the latest effect report counts. `assess` is refused with `NotSettled` before the occurrence settles (#adr(25)).],
      [`record_failure`], [Records one attempt per call while nothing is recommended, so a repeated call records the attempt again; it writes nothing once a recommendation exists.],
      [`record_refusal`], [The same rollback token twice appends once and returns the occurrence (#adr(27)).],
    ))
  ]
])

#section(title: "Cards and verdicts", lead: "A verdict is given on a card, a card is a recorded showing, and a showing binds the verdict to the output it showed.", body: [
  #entity(id: "card", title: "Card", description: [An occurrence as it was shown to one validator. Opaque; only `open` and `resume` construct one.], kind: "value-object", owner: "decisions desk", lifecycle: "immutable", domain: "record", tint: "violet")[
    #attribute(name: "Occurrence", type: "The occurrence as shown", provenance: "derived")[Every entry up to the card's last action.]
    #attribute(name: "Holder", type: "Validator", provenance: "authored")[Who the card was shown to, with the sets held in the session.]
    #attribute(name: "Seen", type: "Sequence number of the showing", provenance: "derived")[The `opened` entry; with the occurrence id it is the ticket.]
    #attribute(name: "Allowed verdicts", type: "The point's verdicts", provenance: "derived")[What a client may offer.]
  ]
  #points(
    [`open(occurrence:, by:, latest:)` opens only an occurrence a verdict can be given on, and records the showing: one awaiting verdicts, to a validator the eligibility admits, or one released and sampled, for its review, limited to the point's reviewers when it names a set. It refuses with `NotEligible`, as `decide` would, anyone no alternative admits (#adr(40)). Any other occurrence is refused with what a card would run into: `AlreadyDecided(by)` when a verdict settled it, `NotSampled` when the policy released it unsampled, and `NotAwaiting` otherwise (waiting for a consulted point, expired, withdrawn, refused, or lapsed). A queue page read before the lock learns it here (#adr(33)). To send a verdict again after a lost reply, resume the card from its ticket.],
    [The showing records every input, a context reference or a read, whose current revision as `latest` gives it differs from the revision the model had. Drift says only that the content differs now: it cannot tell a change in the world from one the release itself caused.],
    [`ticket(card)` is the occurrence id and the showing's sequence number: what a page or another system keeps between requests. `resume(ticket, by:)` returns the same card and writes nothing. It refuses a ticket that names no showing to that validator (`NeverShown`), a lapsed occurrence (`NotAwaiting`), and a ticket shown before another validator's correction (`OutputChanged`).],
    [`expand(card, read:, result:)` records what the validator looked up beyond the card as captured evidence; `note(card, text)` records what they know from outside it. Both refuse a lapsed occurrence and return the next card.],
    [`decide(card, verdict)` checks, in order: a recorded showing to the holder at the card's `seen`; the deadline by the store clock; that no one else corrected the output after that showing; eligibility; and that the point allows the verdict, a rejection or correction has a reason category, and a missing-context reason has a note by the same validator.],
    [Each `decided` entry records the decision sets its validator held when they gave it. An approval of the standing output is credited with those sets; a correction replaces the standing output and counts as its author's approval of the new one, and approvals of the earlier output stop counting.],
    [Eligibility is evaluated per alternative over the approvals so far (`occurrence.is_met`). `AnyoneHolding(set)` is met by one approval from a holder of the set, `SomeoneElseHolding(set)` by one from a holder who neither asked nor recommended it as their own act, `Several(count, of)` by `count` different approvers each admitted by `of`, and `Either(list)` when any one alternative is met. A `Several` inside another `Several` and an `Either` with no alternative are unpublishable (`NestedSeveral`, `EmptyEither`; #adr(41)). So `Either([Several(2, AnyoneHolding("finance")), AnyoneHolding("head")])` accepts on two finance approvals or one by the head, never on one finance approval (#adr(29)). A validator may decide when any alternative admits them (`occurrence.admits`).],
    [A validator who approved the standing output may not approve again, reject or correct it (`NotEligible`); after someone else corrects it they decide again on the new output.],
    [A verdict is bound to its #term("term-showing") so that it is never counted for an output the validator did not see (#adr(11)).],
    [`SomeoneElseHolding(set)` excludes the requester and a person who recommended as their own act, so a recommendation by one person asked for by another excludes both.],
  )
  #behavior(title: "A stale card cannot approve a correction it never showed", area: "Verdicts", level: "boundary")[
    #given[A validator holds a card shown before another validator corrected the output.]
    #when[The validator gives a verdict on that card, directly or through its ticket.]
    #then[The verdict is refused as given on a changed output, and nothing is written.]
    #then[The validator can open the card again and decide on the output that stands.]
  ]
  #behavior(title: "A verdict after the deadline is refused", area: "Verdicts", level: "boundary")[
    #given[An occurrence whose deadline has passed by the store clock, and whose expiry wake-up has not been delivered.]
    #when[A validator opens, notes, expands, resumes or decides it.]
    #then[The verb is refused as not awaiting, and nothing is written.]
  ]
  #behavior(title: "A verdict sent again stands", area: "Verdicts", level: "boundary")[
    #given[A validator's verdict on a card committed and the reply was lost.]
    #when[The same verdict is sent again on the same card or ticket.]
    #then[The occurrence is returned as it stands and nothing runs again.]
    #then[Another validator's verdict on the settled occurrence is refused with who decided.]
  ]
])

#section(title: "Gated tools and release", lead: "An accepted output passes its guard and reaches its executor once, inside the transaction that records the release.", visual: sequence(
  title: "A refusal at release rolls back and is kept on the record", participants: (
    (id: "app", label: "Caller", shape: "control"),
    (id: "desk", label: "Desk", shape: "participant"),
    (id: "store", label: "Store", shape: "database"),
    (id: "tool", label: "Gated tool", shape: "boundary"),
  ), steps: (
    seq-msg("app", "desk", "decide(card, Approve) in transaction 1"),
    seq-msg("desk", "store", "load and lock; read the clock"),
    seq-msg("desk", "store", "savepoint"),
    seq-msg("desk", "tool", "guard(subject), check(to_release), execute(released)"),
    seq-msg("tool", "desk", "Error(Refuse(reason)) after writing", dashed: true),
    seq-msg("desk", "store", "roll back to the savepoint"),
    seq-msg("desk", "app", "ToolRefused(reason, rollback)", dashed: true),
    seq-note("app", "transaction 1 rolls back; the occurrence still awaits"),
    seq-msg("app", "desk", "record_refusal(rollback) in transaction 2"),
    seq-msg("desk", "store", "append verdict_refused"),
  ), caption: [The rollback token carries the point, the occurrence, the validator, the showing, the verdict and the reason. Only the desk makes one, so the record can show only a refusal that happened.],
), body: [
  #points(
    [A gated tool is `Gated(name:, guard:, execute:)`. `drives` picks the tool from the final output, so a point whose output has variants drives one tool per variant. The guard receives the transaction and the subject and returns the evidence it relied on. The executor receives a `Released(output)`. Each of the guard, the release check and the executor fails with `decisions.Stop`: `Refuse(reason)` refuses this release for good; `Unsure(reason)` says it could not tell, such as a lost connection (#adr(37)).],
    [Release runs, inside the port's savepoint (`atomically`), the guard, then the release check the desk was given with `checking`, then the executor. The check receives a `ToRelease(output, subject, context, key)` value, which no executor accepts, so it can compare a fact of the world with the output without being able to perform the effect; `Released` is built only for the executor (#adr(38)). When all succeed the desk appends `released` with the release key, the tool's name, and the evidence the guard and the check relied on. An executor must not keep the `Released` value beyond its call.],
    [`Unsure` from any of the three rolls the savepoint back, records nothing as refused, and fails the verb with `ToolUnsure(reason)`, so the caller or a runtime tries again, counted. `Refuse` undoes what the tool wrote and is a refusal: with a validator present the verdict rolls back (`ToolRefused`); with nobody waiting the occurrence ends `refused`. The guard's parameters carry no output, but a `drives` function can close over the output when it builds the gated tool; a check that needs the output belongs in the release check, where its evidence is recorded, and a threshold on the output alone belongs in the policy (#adr(31)).],
    [What a refusal does depends on who waits. When a verdict completed the acceptance, the verb fails with `ToolRefused(reason, rollback)` so the verdict's transaction rolls back and the occurrence keeps waiting. When the policy proceeded or a hold ended, nobody waits, and the occurrence ends `refused` with the reason.],
    [A released output exposes its output, its release key (`release:` and the occurrence id), its subject, its occurrence id, its parent and its decider. The executor cannot construct one or hand one on; the fixtures `build_a_released_value` and `execute_with_a_bare_output` fail to compile.],
    [An effect outside the database is three pieces: the executor writes an instruction beside the release; something performs it under the release key; and `report(effect:)` records whether it was performed with a receipt, not performed, or uncertain. An uncertain effect is settled only by looking it up by the release key, and the latest report counts.],
    [A guard that needs an outside fact does not call the network in the verdict's transaction. A check captures the fact as evidence first; the guard reads that evidence, judges its age, and returns it, so the release names what it relied on. A provider that is down refuses the release with a reason that says so.],
  )
  #subsection(title: "Hold and withdrawal")[
    #points(
      [A point with a hold appends `held(until)` on acceptance instead of releasing. The point's `with_hold` holds every acceptance. A policy outcome `Proceed(sample:, hold:)` that carries a hold is used instead for what the policy accepted by itself: an undo window on autonomous decisions, published as data with the policy version. A hold of zero or less is unpublishable (`NonPositiveHold`). When the hold ends, `wake` runs the guard, the release check and the tool against the world as it is then and releases or ends `refused`; a refusal then never reaches the validator who approved, who was already answered. A newer event declared with `superseded_by` supersedes a held occurrence: its wake-up is cancelled and nothing is released (#adr(49)).],
      [`withdraw(by:)` lets the decider take the output back while the store clock is before the hold's end. The decider is the validator whose verdict accepted it, or the person whose own act the policy let proceed; for an output the policy accepted from a model that is nobody. `withdraw_as(by: validator)` also admits a holder of the set the point names with `withdrawn_by` (`NotTheDecider` for anyone else). After the end both are refused with `NotHeld`, whether or not the wake-up was delivered (#adr(30)).],
    )
    #behavior(title: "A withdrawal after the hold ended is refused", area: "Release", level: "boundary")[
      #given[A held occurrence whose hold has ended by the store clock and whose wake-up has not been delivered.]
      #when[The decider withdraws it.]
      #then[The withdrawal is refused as not held and nothing is written.]
      #then[The next wake-up releases it or ends it refused.]
    ]
  ]
])

#section(title: "Time", lead: "The record carries every time that matters, and the store clock decides when it is reached.", body: [
  #points(
    [Every verb reads the store clock after `load` has locked the occurrence, reduces it to whole milliseconds (rounded down), and never uses a time earlier than its last entry. A verb that waited for the lock is stamped with when it ran. Every time the desk stores, schedules or puts on a head is a whole millisecond, so an adapter with a finer clock cannot store a time a wake-up or a head would not match.],
    [The deadline is fixed on the record: on the expectation when the application gives one, and as the #term("term-effective-deadline") on the recommendation. A deadline of the occurrence's own and one from the point's validity fold into one deadline, with one wake-up and one cause; once recommended, the same refusals apply. A deadline ends the wait for a decision, not a hold: an occurrence accepted and held before it is released when the hold ends; a guard or a release check enforces the deadline where nothing may happen after it. An undecided occurrence at or after its deadline is lapsed: every verb that shows or writes on it refuses with `NotAwaiting`, `inform` refuses, and `happened` records `expired` as deadline passed, which is what ended it.],
    [`wake(occurrence:)` acts only on what is due by the store clock: a held occurrence whose hold ended is released; a lapsed occurrence expires; a lapsed record not begun expires and the answer is `LapsedBefore(pending)`. On an awaiting occurrence it applies, in order, the passed steps of the timeline, and stops at the first that proceeds, consults a point not yet consulted, or asks for what the approvals given so far already meet; otherwise it applies the last passed step. So a wake-up delivered late reaches the outcome one delivered on time would have, and a step that asks for what the standing approvals meet accepts (#adr(42)). Otherwise it writes nothing and returns `NotDue(until)` with the next time, always in the future, or `NothingDue`.],
    [`waker(desk)` is `wake` with the output type erased, as `#(point name, handler)`, so one job handler serves every point. The handler returns `None` when the job is done and `Some(until)` when it must be delivered again at `until`.],
    [The store clock, not the arrival of a job, decides whether a deadline or a hold has passed (#adr(8)). A #term("term-wake-up") only asks the desk to look.],
    [The desk compares the occurrence's wake times (`occurrence.wake_times`: the hold's end, or the deadline and each step at or before it; `occurrence.pending_wake_times` for a record not begun: its deadline) before and after every verb, and calls the port's `schedule` when they differ. A settled occurrence has none, so settling cancels its wake-ups.],
  )
  #behavior(title: "An occurrence expires at its own deadline", area: "Time", level: "boundary")[
    #given[A key expected with its own deadline, on a point that declares no validity or a longer one.]
    #when[The store clock reaches the deadline, before or after the recommendation.]
    #then[The record expires as deadline passed, by the wake-up or by the recommendation that comes after it.]
    #then[A verdict, a failed attempt or another expectation for the key is refused, and nothing is written.]
    #then[A key expected with `expect` alone has no deadline until it is recommended.]
  ]
  #behavior(title: "A wake-up that arrives early says when to come back", area: "Time", level: "boundary")[
    #given[A held occurrence whose hold has not ended by the store clock.]
    #when[A wake-up for it is delivered.]
    #then[Nothing is written and the answer names the hold's end, a time in the future.]
  ]
])

#section(title: "The world: superseding and consulting", lead: "Events about a subject expire what waits for it, and a policy may ask another point first.", body: [
  #points(
    [`happened(event, about:)` does nothing unless the point declares the event with `superseded_by`. It first loads the subject lock for the point and the subject, then asks the port for the point's records about the subject that have released nothing (pending, recommended, awaiting or held), in ascending id order so every transaction locks them in one order. It supersedes each: a record that has not begun (expected, or holding only failed attempts) is superseded before it began, or expires as deadline passed rather than superseded when its own deadline had passed, and in both cases its wake-up is cancelled and its key is reported in `not_begun`; an undecided occurrence expires, as deadline passed when it had already lapsed; a held occurrence expires and its hold's wake-up is cancelled, so nothing is released. A released occurrence is untouched. It returns `Supersession(expired, not_begun, unreadable)`; an unreadable record does not stop the others, and each superseded record admits one settlement notice (#adr(49), #adr(50)).],
    [A policy outcome `Consult(point)` records the answer and then calls the consult handler wired with `consulting`, in the same transaction, with a consultation: the point, the occurrence, its subject, its context and its recommendation. The handler recommends at the consulted point, whose gated tool calls `inform` on this occurrence in this transaction or a later one. A handler that fails is `ConsultFailed`.],
    [`inform(from:, facts:)` requires that the occurrence waits for exactly that point (`NotConsulting`), that every fact is declared with its type (`InvalidFacts`), and that it has not lapsed. It appends the answer and reads the policy current at that moment again with the new facts. A policy that would consult the same point twice falls to its default.],
  )
  #behavior(title: "One unreadable occurrence does not stop superseding", area: "Superseding", level: "boundary")[
    #given[Several undecided occurrences about a subject, one of which no longer decodes.]
    #when[A declared superseding event about the subject is reported.]
    #then[Every readable undecided occurrence expires as superseded.]
    #then[The unreadable one is reported with its reason.]
  ]
])

#section(title: "Policy as data", lead: "Every condition for proceeding without a person is a versioned value that reads only declared facts.", body: [
  #md-table(3, (
    [*Value*], [*Variants*], [*Meaning*],
    [`Policy`], [`Policy(version, rules, otherwise)`], [The first rule whose condition holds decides; `otherwise` decides when none does.],
    [`Outcome`], [`Proceed(sample, hold)`, `Ask(eligible)`, `Consult(point)`], [Proceed without a person, optionally after a hold; wait for verdicts; or ask another point first. A hold is stored as `hold_ms`; absent means no hold.],
    [`Sample`], [`Never`, `PerCent(n)`], [Which proceeding occurrences wait for a review. `policy.is_sampled` hashes the occurrence id with SHA-256, so the share is uniform whatever the ids look like and a replay samples alike (#adr(32)).],
    [`Eligible`], [`AnyoneHolding(set)`, `SomeoneElseHolding(set)`, `Either(list)`, `Several(count, of)`], [Who may give the verdict, and how many approvals it needs; `policy.approvals(Either)` is the fewest any alternative needs.],
    [`Condition`], [`OwnAct`, `Below`, `AtLeast`, `Is`, `Known`, `All`, `AnyOf`, `Not`], [Over the recommender and named facts.],
    [`Step`], [`Step(after, outcome)`], [A later answer after whole minutes waited.],
  ))
  #points(
    [A condition over an absent fact is unknown, stays unknown under `Not`, and never matches, so what is unknown never proceeds. `All` is false when any part is false and unknown when any part is unknown; `AnyOf` is true when any part is true.],
    [The facts a policy reads are the output's declared facts, the recommender's signals, what consulted points returned, and `waited_minutes`, the whole minutes since the recommendation. A rule over the time waited makes the policy change its answer as the occurrence waits: escalation to a second set, expiry by validity, and "proceed if nobody objects within the hour".],
    [When the desk applies a policy it computes the timeline: the answer now and each later answer at every threshold of the time waited the rules name. The steps are kept on the `policy_applied` entry. A wake-up applies the next step without reading the policy again, so an occurrence keeps the version it was given while it waits. A consulted point's answer is the one moment the policy is read again, and then the version current at that moment applies. Every `policy_applied` entry records the version that gave its answer.],
    [Publishing a version is a write wherever the application keeps it; the desk reads it through its policy function in the caller's transaction. `publishable(point, policy)` lists every fault: an undeclared fact, a fact compared as the wrong type, fewer than one approval, a `Several` inside another `Several` (an inner count would be ignored), a hold of zero or less on `Proceed` (`NonPositiveHold`), an `Either` with no alternative (the occurrence would wait in no queue), a sample outside 0 to 100. The desk checks it again on every read and refuses with `Unpublishable`.],
    [#adr(13) records why the policy is data rather than code, and why it is checked against the point's #term("term-declared-fact") list.],
    [A policy is plain data. `to_json` and `decoder` round-trip it, and a policy read back is equal to the one written: `Never` is stored as a null sample and `PerCent(0)` as zero.],
    [Typed fact keys (`fact.number`, `fact.text`, `fact.flag`) carry a fact's name and type. A policy written in Gleam with `policy.below`, `policy.at_least`, `policy.is` and `policy.known` uses the key the point declared, so a misspelt name or a number rule on a text fact does not compile.],
  )
])

#section(title: "Models and reads", lead: "A model is a function of its context and its sources, and the record holds the reads it received.", body: [
  #md-table(3, (
    [*Constructor*], [*Reads recorded*], [*For*],
    [`model.new(call)`], [Observed: every read the sources answered while it ran.], [A rule, a classifier, one provider call.],
    [`model.over(reader, decide)`], [Observed.], [A model that decides from a typed context its reader builds.],
    [`model.reporting(call)`], [Reported: the reads on its recommendation, believed.], [An agent loop whose tool can read and then fail.],
    [`model.over_reporting(reader, decide)`], [The reader's reads observed, and the reads `decide` reports.], [An agent that starts from a typed context.],
    [`model.cascade(stages)`], [Only the reads of the stage that answered.], [Cheap stages first; a stage abstains with `None`. No answer is `Declined`. `model.stage(model)` turns a model into a stage: `Declined` abstains, any other failure stops the cascade.],
  ))
  #points(
    [`model.run` is the only way to call a model; the fixture `call_a_model_without_run` fails to compile. It puts the reads the model received on the recommendation, contains a model that raises as `Raised`, leaves nothing it set up behind, and answers a read made after the model returned without recording it.],
    [`Sources` has `resolve`, for a context reference, and `read`, for a named read with one argument that returns the content with its evidence reference. `model.capture` fetches from an outside system, stores the response as evidence under a reference whose revision is the SHA-256 digest of the content (`model.digest`), and only then returns it; a failed fetch stores nothing. `model.recorded` answers from a record and from nothing else: anything it does not hold is `NotRecorded`, and of several reads with one name and argument the last answers.],
  )
  #md-table(3, (
    [*Failure*], [*Meaning*], [*A retry can help*],
    [`NotRecorded(read, argument)`], [The record holds no answer; under replay the example is unanswerable.], [No],
    [`ReadFailed(read, argument, reason)`], [A source failed to answer.], [Yes],
    [`Deadline(after)`], [No answer within the deadline.], [Yes],
    [`ProviderFailed(provider, reason)`], [The model's provider could not be reached or answered with an error.], [Yes],
    [`Raised(reason)`], [The model raised.], [Yes],
    [`Undecodable(reason)`], [The answer does not decode as the output.], [Yes],
    [`Declined(reason)`], [The model declined, or no cascade stage answered.], [No],
  ))
  #points([`model.retryable(failure)` answers the last column. A failed attempt is recorded with `record_failure` in a transaction of its own; #adr(9) records why reads are counted as received and #adr(10) why failures are recorded.])
])

#section(title: "The card as a document", lead: "A card shows the same context the model had, resolved from the record, and crosses a process boundary as JSON.", body: [
  #points(
    [`view.of(card, content:)` builds what a card shows. `content` is a `model.Resolver`, the one type the card, the context and the export take: it resolves a reference to the evidence it names, the content as it was read whatever the world says now, or `NotRecorded`. The point's name and verdicts come from the card, so a view cannot be built against the wrong point.],
    [`view.context(shown, with: reader, content:)` runs the point's reader against the record alone: the context references and the reads on the recommendation. It returns the same typed value the model's reader returned, or `NotRecorded` for a read the model never received.],
    [Drift is computed when the card is opened: every context reference and every read whose `latest` revision differs is recorded on the showing with its newer revision, and the view marks each such item with what it changed to.],
  )
  #md-table(2, (
    [*Field of `decision-card.v1`*], [*Content*],
    [`format`, `occurrence`, `seen`], [The format name and the ticket.],
    [`point`, `subject`, `status`], [What the card is about and where it stands.],
    [`waiting_for`, `approvals`], [The sets it waits in; who has approved the standing output, and for each alternative of the eligibility its sets, how many approvals it has and how many it needs (`view.Approvals(by, alternatives)`), so a card under `Either` never shows one alternative's count as the whole.],
    [`context`, `model_read`], [The context items and the reads the model received, each with its reference, its content as read (null and `unavailable` when unresolved), and `changed_to`.],
    [`opened`, `notes`], [What validators opened beyond the card, and their notes.],
    [`recommendation`, `standing_output`], [What the recommender proposed, and the output a verdict on this card would be about.],
    [`verdicts`, `output_schema`], [The allowed verdicts, and the output's JSON Schema when the codec carries one, so a client can build a correction form.],
  ))
  #points(
    [The document is exactly the encoding of `view.codec(output)`, a json_blueprint codec that carries the document's JSON Schema, so a client that has the same codec decodes it typed. Decoding is faithful except for an input that could not be resolved: it is marked `unavailable` and comes back as `ReadFailed` with the reason's text. A copy of the card codec costs the document's own codecs and about twelve copies of the point's codec, and nothing else from outside the document (#adr(57)). Encoding re-reads JSON text that the point's codec and the wire forms have just written, so it parses that text without json_blueprint's limits for untrusted input, and an output of any depth or size encodes. Decoding a client's text is bounded by the limits the application passes to json_blueprint: `codec.decode_json` refuses more than 1 MiB or more than 128 levels of nesting.],
    [A verdict returns as JSON decoded with the point's own codec (`view.verdict`); a correction whose output is not the point's output does not decode. `view.ticket_decoder` reads the ticket back from a card document. A client needs none of the point's code to render a queue, approve or reject.],
  )
])

#section(title: "Learning", lead: "Agreement, accuracy, export and replay are folds over records; none writes and none needs a store.", body: [
  #points(
    [`learning.tally(occurrences)` counts per recommender value, and `learning.replay` judges by the same rule, so the two agreement figures have the same denominator (#adr(24)). An occurrence is judged when people let an output through to acceptance: it was accepted, held, released, or accepted and then refused by the tool. Walking its verdicts and then its reviews in order, an approval lets through the output that stands, a correction lets through its own output, and a rejection lets nothing through; a person's own act counts as that person's judgment of the output they proposed. Each judged occurrence counts once. In the tally it agrees when the output let through is the recommended output.],
    [An occurrence that was rejected, or whose review rejected it, is not judged by either fold and is counted in `rejected`. Not judged and not counted: an output the policy accepted with no verdict and no review; a partial quorum that expired, since approvals that never reached acceptance are not a judgment; and a withdrawn occurrence, since withdrawing says the decider changed their mind, not what the right output was. Each assessment counts toward accuracy: right of assessed.],
    [`learning.example(occurrence, as_of:, from: archive)` exports an occurrence as known at a stated time: the entries up to then, the prompt the archive's renderer builds from the context, the content of every context reference and read, reads retained elsewhere that the archive returns for the explanation, and what validators opened. `example_to_json` writes it as `decision-example.v1`.],
    [`learning.replay(examples, candidate, same:)` runs a candidate through `model.run` with each example as its whole world. It calls no gated tool, writes no record, and reports a candidate that raises or asks for what the record lacks as unanswered. `replay_one` and `merge` are its pure halves, for spreading examples over processes.],
    [Replay judges the same occurrences as the tally, so `replay(..).tally.judged` equals the recorded tally's `judged`; the candidate agrees when its output is `same` as the output people let through. Accuracy is scored against what proved true: the truth an assessment names, or the final output when an assessment found it right; when an assessment found the output wrong with no truth named, only a candidate that repeats the wrong output is scored, as wrong.],
    [`learning.answer_under(example, policy:, point:)` says what a candidate policy would have answered for a recorded example when it was recommended, with no time waited. Beside `replay` it shows, before publishing a version, how many recorded occurrences it would have let proceed and how many of those people corrected or rejected.],
    [`learning.widened(example)` adds what validators opened beyond the card to what a candidate may read: the context as the validator saw it. A candidate can then be scored on what the model had and on what the person had, which tells a model that lacked an input from a model that judged badly.],
    [Drift in a recommender's results is visible as falling agreement or accuracy per recommender value. The response is a policy version: a point is demoted from proceeding to asking by publishing it, with no code change.],
  )
])

]
