# Independent review after the build is part of the build

<a id="adr-0047"></a>

## Decision

- Each package is reviewed by an agent that did not build it, with probes that must pass while a defect is present, and the build is not finished until each finding is decided, fixed with a test that fails without the fix, or recorded as open.
- The ADRs that record what a review decided carry the finding itself, not only a pointer to the review.

## Rationale and alternatives

- Three reviews ran on 2026-11-15 and each found what the builders' tests did not: the first review of the core (stale cards, a stuck consulting step, withdrawals after the hold, refusals recorded from anything, four-eyes bypassed, a weak clock check; ADRs 0008, 0011, 0012, 0014); the final review of the core (a back door to release without acceptance, a nested count ignored, a late wake-up skipping a step, two classification errors, tests that could not fail; ADRs 0037 to 0042); the review of both adapters (lost commits on restart, half-applied commits, skipped settlements, a stuck job blocking the queue, pending rows with no job, unbounded names; ADRs 0043 to 0046).
- Relying on the builders' own tests was rejected on that evidence: in each review, mutations the review made passed the builders' suites.

## Evidence and history

- The reviews' notes and probes were in the session scratch folder `/private/tmp/claude-501/-Users-edgar--claude-spares-spare-gvvzt1/bbc85f7c-e442-4c65-b31b-5889f7327b02/scratchpad/`: `core-review/` (first core review: `CORRECTIONS.md`, `probe/`), `final-review-core/` (`probe/test/frprobe_test.gleam`, `mutants.py`, with `core-review/FINAL-CORE-CORRECTIONS.md`) and `final-review-adapters/` (`otp_probe/`, `pg/probes.sh`, `mutants/`, with `core-review/FINAL-ADAPTER-CORRECTIONS.md`). These are session scratch files and will not outlive the session, which is why each ADR states its finding in full.
- The corrections are proved by the tests the packages now carry, cited in each ADR.
