#import ".render/designlib.typ": *

#let title = [Decisions]
#let accent = "slate"
#let index_only = true
#let body = [
#section(title: "Foundation", lead: "Decisions keeps the record of each decision point and releases its final output once.", body: [
  #goal(title: "One record for every decision a model and a person make")[A recommender proposes an output, a policy proceeds or asks a person, the person approves, rejects or corrects, and the final output reaches a gated tool at most once. Everything that happened is an append-only record, and that record is the data the system learns from.]
  #no-goal(title: "A workflow engine, a job queue, or an agent runtime")[The library starts no process in its core and owns no delivery. Grind delivers time and settlements, Fabric runs agents, and the application owns its pools, its transactions and its supervision tree.]
  #invariant(title: "A final output reaches its gated tool at most once", enforcement: "mechanism")[The store refuses a second `released` entry for an occurrence, and an executor accepts only a released output, which only the desk constructs during a release.]
  #invariant(title: "The record is the only authority", enforcement: "mechanism")[Where an occurrence stands is a fold of its entries. A head, a queue row, a pending wake-up, a hint and a telemetry event are each derived from the record or written in the transaction that appends to it, and none of them decides an outcome.]
  #principle(title: "Time and the record decide, never the delivery of a job")[A verb compares the store clock, read after the lock, with the times on the record. A wake-up that arrives early, late, twice, or never changes when a deadline or a hold ends by nothing.]
  #principle(title: "Keep the core pure and put processes around it")[An occurrence is a record, not a process. The core performs no I/O and starts no process; everything that needs a process lives in a separate package and keeps no state a kill could lose.]
])

#section(title: "System at a glance", lead: "Three packages in one repository; the application wires them to its own store and libraries.", visual: diagram(
  altitude: "L1", viewpoint: "runtime", title: "The packages and who depends on whom",
  nodes: (
    (id: "app", label: "Application", sub: "points, gated tools, policies, wiring", kind: "external-system", tint: "slate"),
    (id: "core", label: "decisions", sub: "pure core: record, desk, policy, view, learning", kind: "component", tint: "violet"),
    (id: "otp", label: "decisions_otp", sub: "process-safe store, runtime, isolated calls", kind: "component", tint: "amber"),
    (id: "pg", label: "decisions_postgres", sub: "port over PostgreSQL, Grind workers, NOTIFY", kind: "component", tint: "teal"),
    (id: "db", label: "PostgreSQL", sub: "the application's database", kind: "database", tint: "slate"),
    (id: "grind", label: "Grind", sub: "durable jobs", kind: "external-system", tint: "slate"),
    (id: "recipes", label: "Recipes", sub: "Fabric, llm_wire, Relay", kind: "external-system", tint: "slate"),
  ),
  edges: (
    (from: "app", to: "core", relation: "call", label: "verbs in its transaction"),
    (from: "otp", to: "core", relation: "dependency", label: "path dependency"),
    (from: "pg", to: "core", relation: "dependency", label: "path dependency"),
    (from: "pg", to: "grind", relation: "dependency", label: "wake-up and notice jobs"),
    (from: "pg", to: "db", relation: "call", label: "port statements"),
    (from: "app", to: "otp", relation: "call", label: "runtime, isolated calls"),
    (from: "app", to: "pg", relation: "call", label: "port, workers, queues"),
    (from: "recipes", to: "core", relation: "call", label: "application code"),
  ), caption: [The core depends on `gleam_stdlib`, `gleam_json`, `gleam_time` and `json_blueprint` only. No package depends on Fabric, llm_wire or Relay; those joins are recipes in the application.],
), body: [
  #points(
    [`decisions` is the repository root. It holds the declaration, the policy, the entries, the fold, the desk, the card document and learning. It builds for Erlang and JavaScript, so a page can fold a card's entries with the library's own code.],
    [`decisions_otp` (`integrations/decisions_otp`) holds what only processes can do: a process-safe in-memory store, the supervised runtime, isolated model calls, parallel replay, live hints and the stress suite. It depends on `decisions`, `gleam_otp`, `gleam_erlang` and `sinal`.],
    [`decisions_postgres` (`integrations/decisions_postgres`) holds the storage port over PostgreSQL, its migrations, the Grind workers that deliver wake-ups and settlement notices, the `NOTIFY` listener and the queue queries. It depends on `decisions`, `pog`, `pgo`, `grind` and `sinal`, with the `pog` and `pgo` ranges equal to Grind's.],
    [Each integration depends on the root by path while the packages are unpublished. The core never depends on an integration. #adr(3) records the split and #adr(4) the recipes.],
  )
  #answers(title: "Decisions", responsibility: [Keep each occurrence's record, decide by policy or verdict, and release the final output to its gated tool at most once.], interface: [A `Point` declaration, a `Desk` with its verbs, a `Policy` as data, the storage `Port`, the card document, and learning folds.], interactions: [The application calls verbs in its own transaction; the desk calls the port, the policy reader, the guard and the executor in that transaction.], invariants: [I1 to I8, held by types, the fold, desk checks, the port contract and database constraints.], failure: [A verb returns a typed refusal and the caller rolls back. A refused release and a failed model attempt are kept on the record by a verb run in a transaction of its own.])
])

#section(title: "Context boundaries", lead: "The record owns meaning; storage owns what a store must guarantee; runtime owns delivery.", body: [
  #md-table(3, (
    [*Context*], [*Owns*], [*Depends on*],
    [#ctx("record")], [The declaration, the occurrence and its entries, the lifecycle, verdicts and cards, gated tools and release, time, superseding and consulting, policy, models and reads, the card document, and learning.], [The storage port's contract, which it states the needs of.],
    [#ctx("storage")], [The storage port and its contract clause by clause, the head, wake-ups and notices as stored, the conformance suite, the invariant check, and the three adapters: memory, OTP and PostgreSQL.], [The entry kinds, statuses and head derivation of the record.],
    [#ctx("runtime")], [The processes around the record: the supervised runtime, the backlog, Grind delivery in PostgreSQL, isolated model calls, parallel replay, live hints, telemetry and the stress suite.], [The verbs and the record of the record context; the port and the stores of the storage context.],
  ))
  #points(
    [The contexts follow vocabulary, not packages. The core package holds the whole record context and the port's definition, memory adapter and conformance suite; each integration package holds part of storage and part of runtime. `docs/COVERAGE.md` maps every part to its owning section.],
    [A term has one owning context. Record owns occurrence, entry, desk, release and wake-up; storage owns port, head, pending wake-up and settlement notice; runtime owns sweeper, dispatcher, worker, hint and stress suite. A context cites another's term and never redefines it.],
  )
])

#section(title: "The invariants and what holds each", lead: "Eight properties hold over every record in every store; each has a named mechanism.", body: [
  #md-table(3, (
    [*Invariant*], [*Statement*], [*Held by*],
    [I1], [At most one release per occurrence; when an audit counts effects, the gated tool's effects equal the released occurrences.], [Type: an executor accepts only a released output, which only the desk builds, for the executor alone; the release check receives a value no executor accepts. Port contract: `append` refuses a second `released` entry. Database constraint: the unique index `decisions_entries_one_release`.],
    [I2], [A release follows an acceptance: the policy proceeded, or the required verdicts approved or corrected.], [Fold: a `released` entry moves only an accepted or held occurrence. Desk check: release runs only from those statuses, under the lock.],
    [I3], [Nothing changes an outcome after it settles. Only assessments, effect reports and recorded refusals are appended, and on a sampled occurrence also its review and the showings, notes and expansions that lead to it. A recorded refusal names a showing to its validator made before settlement.], [Fold: an entry that is illegal from a settled status leaves the status unchanged. Desk check: every verb that changes an outcome requires an undecided or held status. Type: `record_refusal` accepts only a rollback token. Database constraint: an append-only trigger on `decisions_entries`.],
    [I4], [One deciding verdict per validator per standing output.], [Desk check: under `Several`, a validator who approved the standing output is not eligible again; the same verdict on the same showing sent again writes nothing.],
    [I5], [Every wake-up the occurrence needs as it stands is pending: the end of a hold, the deadline, and each later step. A settled occurrence has none.], [Desk check: every verb compares the occurrence's wake times before and after and calls `schedule` when they differ. Port contract: `schedule` replaces the pending wake-ups.],
    [I6], [A settled occurrence has exactly one settlement notice; an unsettled one has none.], [Desk check: `settled` is called in the transaction in which the status becomes settled, and only then. Database constraint: `decisions_settled_once`.],
    [I7], [Entries are numbered 1, 2, 3 and so on and their times never decrease, so the record as known earlier is a prefix of the record now.], [Desk check: the clock is read after the lock and never earlier than the last entry. Port contract: `append` refuses a repeated number and a gap. Database constraints: the primary key and the foreign key `decisions_entries_no_gap`.],
    [I8], [The head equals the head the record implies, field by field.], [Desk check: the desk derives the head from the folded occurrence and writes it with every append. Port contract: `append` replaces the head with the entries in one write.],
  ))
  #points(
    [`decisions/testing.check` checks all eight over any store through its inspection, after a race, a random walk, a kill or a restart. Its I3, I4 and I5 are stated above as the code checks them; #adr(12) records why I4 counts per standing output.],
    [I1 bounds the database effect exactly. An effect outside the database is bounded by the release key: the outside system deduplicates by it, and an uncertain outcome is settled by looking the effect up by it (#adr(7)).],
  )
])

#section(title: "What the application owns", lead: "The library stops at the record and the port; everything that needs a decision of the deployment is the application's.", body: [
  #md-table(2, (
    [*The application owns*], [*Why it is not the library's*],
    [Its transactions, its connection pool and its Grind runtime], [A verb runs in the caller's transaction so that the verdict, the application's own writes and the gated tool's writes commit together.],
    [The points, their codecs, their gated tools and guards, and where each policy version is stored], [These carry the application's types and meaning. The desk reads the policy through a function the application supplies.],
    [Who holds which decision set], [Membership is a fact of the validator's session, never of the record.],
    [Delivery: registering the Grind workers, or starting the OTP store and runtime in its supervision tree], [Capacity, queues and supervision are deployment choices. The OTP store goes first under a `RestForOne` supervisor with the runtime after it, because a restarted store is empty and every earlier handle fails.],
    [Closing the superseding window], [It keeps the latest trigger per subject in its own row and checks it inside the recommending transaction (#adr(34)).],
    [The follower of each point and the follow-on run], [What comes after an occurrence is application behavior; it must build its context from the world as it is.],
    [The evidence store, the renderer and the archive used for export], [Where content lives and how a context becomes a prompt is the application's.],
    [The Fabric, llm_wire and Relay recipes], [None of the three packages depends on them (#adr(4)).],
  ))
  #subsection(title: "Recipes")[
    #points(
      [A Fabric agent recommends in its typed final answer, explained by `RunAnswer`. An agent whose loop reaches a gated act is parked by a Fabric policy that requires an approval, with an approval that never expires, and the parked call is recorded as an occurrence. Two ways of answering it are built. The lab's recipe ends the parked run and starts a fresh run as the follow-on. The `payout_desk` application resumes the same parked run from the decision point's record: only the decision point answers the approval, the gated tool returns the recorded outcome, and a reply reaches the customer only when it matches the record. The reads come from the run's succeeded actions and are reported (#term("term-reported-reads")).],
      [One llm_wire call captures the exact request and the answer as one evidence document, so the card can show the byte-identical prompt and a replay needs no transport while the request bytes are unchanged.],
      [Relay serves points over MCP as tools; the caller is the connection's context. A generic client needs the output type erased behind closures, which is pending in the #ctx("record") context.],
      [Fabric has no tool outcome that ends a run. Until it has one, a parked run that is not ended can wake when its approval expires and tell a customer something the record contradicts. Both ways avoid the trap with Fabric as published, and neither can make Fabric end a run from a tool outcome, which is why the request stands. The request to Fabric's maintainers is drafted in `docs/requests/fabric-tool-outcome-that-ends-a-run.md`; #adr(17) records the decision to ask.],
    )
  ]
])

#section(title: "Verification gates", lead: "Shared tools check the layer and formatting; the package tests check behavior.", body: [
  #md-table(3, (
    [*Evidence*], [*Guarantee checked*], [*Boundary*],
    [Root package tests (108)], [Every use case, every designed-out defect and every correction, as scenarios over the memory store; the conformance suite against the memory store and against a broken adapter for each clause.], [One process; the memory store serialises nothing.],
    [`examples/usage`], [Ten usage topics as compiled modules, each asserting what it shows (#adr(16)); the OTP and PostgreSQL wiring as compiled test modules of their packages.], [A separate package that imports only public modules.],
    [`fixtures/negative` with positive controls], [Thirteen shapes the compiler refuses, from a bare output handed to an executor to a number rule on a text fact.], [Actual compiler failures with expected diagnostic fragments; each control compiles.],
    [`scripts/check_javascript.sh`], [Every public core module builds for JavaScript and one scenario runs there.], [Node.js; one scenario.],
    [`integrations/decisions_otp` tests (74)], [The OTP store passes the conformance suite with a stopped and a moving clock and the twenty stress scenarios; the runtime's kills; isolated calls; live hints; moderation at volume.], [Real processes against a real transaction boundary; one VM.],
    [`integrations/decisions_postgres` tests (57)], [The adapter passes the conformance suite and the twenty shared stress scenarios; its own races, kills and restarts; Grind delivery; constraints; migrations; queue plans.], [A throwaway PostgreSQL 16 cluster made by `scripts/test-postgres.sh`, with fsync off; the shared scenarios at the light load in `gleam test`, at the default load with the `stress` argument.],
    [Oversight applications], [`clinic_registration`, `payout_desk` and `moderation_desk` use the packages end to end; their friction drove the application round (#adr(36)).], [On Oversight's branch `decisions-examples`, not yet merged, and recorded in Oversight's design layer with its ADRs 0033 to 0036. They resolve `decisions` by a local path that works only from that worktree's depth until this repository is pushed.],
    [Independent reviews], [Three reviews by agents that did not build the packages: the core twice, both adapters once; each finding is fixed with a test that fails without the fix, or recorded as open (#adr(47)).], [Their probes and notes were session scratch files; the ADRs carry each finding.],
    [Scale runs], [H1 to H6 and moderation at volume against the OTP store (`integrations/decisions_otp/bench`) and PostgreSQL (`scripts/test-postgres.sh scale`).], [Observational; gate nothing. Method, machine and numbers in `docs/BENCHMARKS.md` (#adr(28)).],
  ))
  #points(
    [`scripts/test.sh` builds every package with warnings as errors, compiles authored Erlang with `-Werror`, and runs the parts in order; CI runs it with `--require-all`. Formatting is `nix flake check`; this layer is checked by `design-gate-check`.],
    [Every model in the tests is scripted; no test calls a provider. The tests establish lifecycle and record behavior, not model quality. The database harness disables fsync, so no test establishes durability across power loss.],
  )
])

#section(title: "End-to-end walkthrough", lead: "A fee refund of 80.00 is recommended, corrected to 60.00, released once and told to the customer.", visual: sequence(
  title: "One refund from recommendation to follow-on", participants: (
    (id: "agent", label: "Recommender", shape: "control"),
    (id: "desk", label: "Desk", shape: "participant"),
    (id: "store", label: "Store", shape: "database"),
    (id: "bia", label: "Validator", shape: "actor"),
    (id: "tool", label: "Gated tool", shape: "boundary"),
    (id: "follow", label: "Follower", shape: "control"),
  ), steps: (
    seq-msg("agent", "desk", "recommend_once(key, 80.00)"),
    seq-msg("desk", "store", "lock key; append recommended, policy_applied"),
    seq-msg("bia", "desk", "open(card)"),
    seq-msg("desk", "store", "append opened"),
    seq-msg("bia", "desk", "decide(Correct 60.00)"),
    seq-msg("desk", "tool", "guard, execute in a savepoint"),
    seq-msg("tool", "desk", "evidence relied on", dashed: true),
    seq-msg("desk", "store", "append decided, released; notice"),
    seq-note("store", "one commit", side: "left"),
    seq-msg("store", "follow", "deliver the notice once"),
    seq-msg("follow", "agent", "start a fresh run"),
  ), caption: [The admission, the opening and the verdict are each one transaction of the caller; the verdict's transaction holds the refund of 60.00, the `decided` and `released` entries and the settlement notice. Nothing between the opening and the verdict holds a lock.],
), body: [
  #points(
    [Ana complains about a late fee. A support agent reads her fee history and proposes a refund of 80.00. The worker admits it with `recommend_once` under a key the trigger owns, so a second delivery of the same message finds the same occurrence. The policy has no rule that matches, so its default asks `finance`.],
    [Bia holds `finance`. She opens the card in one request and gets a ticket; the card shows the complaint, the fee history as the model read it, and any input whose revision changed since. Caio does not hold `finance` and is refused with `NotEligible`.],
    [In a later request Bia resumes the card from its ticket and corrects the amount to 60.00 with a reason. The correction completes the acceptance, the point has no hold, and the guard and the gated tool run in her transaction inside a savepoint. The refund of 60.00, the `decided` and `released` entries, the head and the settlement notice commit together. The record keeps both amounts.],
    [Had the tool refused, her transaction would roll back with `ToolRefused` and a rollback token, and a second transaction would keep the refused verdict on the record with `record_refusal`. The occurrence would still wait.],
    [The settlement notice is delivered once to the point's follower, which starts a fresh run with the outcome in its context. The first run was ended when the occurrence was recorded and never continues. Later an assessment can record whether 60.00 was right, and a replay can score a new model against Bia's verdict.],
  )
])

]
