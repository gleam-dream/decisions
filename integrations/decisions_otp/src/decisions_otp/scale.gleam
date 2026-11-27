//// The workloads of condition H and use case 12, written once against a
//// `decisions_otp/stress.Target`, so that any store can be measured with
//// the same work. Each returns what it measured; printing and the
//// statement of load and machine belong to the caller (the `bench`
//// package beside this one prints them for the in-memory store).
////
//// Every workload asserts that the work was done as well as timed: a
//// count that does not match is an `Error`, not a number.
////
//// ```gleam
//// import decisions_otp/scale
////
//// let assert Ok(ms) = scale.h1(target, count: 10_000, processes: 4)
//// ```

import decisions
import decisions/fact
import decisions/learning.{Archive}
import decisions/model
import decisions/occurrence
import decisions/policy.{
  type Policy, AnyoneHolding, Never, PerCent, Proceed, When,
}
import decisions/store
import decisions/vocabulary.{
  type Manifest, type Recommender, Approve, ApproveRejectOrCorrect, Assessment,
  Classifier, Manifest, Person, Recommendation, Ref, Right, RuleFired, Rules,
  Subject, Trigger, Validator, Wrong,
}
import decisions/wire
import decisions_otp/replay
import decisions_otp/runtime
import decisions_otp/stress.{type Target}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration

const ana = Subject(kind: "person", id: "ana")

fn score() -> fact.Key(Float) {
  fact.number("score")
}

fn point(
  name: String,
  hold: option.Option(duration.Duration),
) -> decisions.Point(String) {
  let point =
    decisions.point(name, wire.text())
    |> decisions.allowing(ApproveRejectOrCorrect)
    |> decisions.superseded_by("superseded")
    |> decisions.signal(score())
  case hold {
    Some(hold) -> decisions.with_hold(point, hold)
    None -> point
  }
}

fn desk(
  target: Target(tx),
  name: String,
  hold: option.Option(duration.Duration),
  policy: Policy,
) -> decisions.Desk(String, tx) {
  decisions.desk(
    point(name, hold),
    drives: fn(_) {
      decisions.Gated(
        name:,
        guard: fn(_, _) { Ok([]) },
        execute: fn(tx, released) {
          target.add(tx, name, decisions.key(released))
          |> result.map_error(vocabulary.Refuse)
        },
      )
    },
    under: fn(_) { Ok(policy) },
    over: target.adapter.port,
  )
}

fn proceeding() -> Policy {
  well_formed(
    version: 1,
    rules: [policy.When(policy.Always, Proceed(Never, hold: None))],
    otherwise: policy.AnyoneHolding("nobody"),
  )
}

fn asking(set: String) -> Policy {
  well_formed(version: 1, rules: [], otherwise: AnyoneHolding(set))
}

fn scoring(share: Int) -> Policy {
  well_formed(
    version: 2,
    rules: [
      When(policy.at_least(score(), 0.9), Proceed(PerCent(share), hold: None)),
    ],
    otherwise: AnyoneHolding("support"),
  )
}

/// Run a verb in one transaction; `Error` with its refusal's text.
fn within(
  target: Target(tx),
  body: fn(tx) -> Result(a, decisions.Refusal),
) -> Result(Nil, String) {
  stress.transaction(target, fn(tx) {
    body(tx) |> result.replace(Nil) |> result.map_error(decisions.describe)
  })
}

fn recommend(
  desk: decisions.Desk(String, tx),
  tx: tx,
  key: String,
  by: Recommender,
  value: Float,
) -> Result(occurrence.Occurrence(String), decisions.Refusal) {
  decisions.recommend_once(
    desk,
    tx,
    key:,
    proposal: decisions.proposal(
      trigger: Trigger(kind: "scale", id: key),
      about: ana,
      context: Manifest(refs: [Ref("input", key, "1")], renderer: "scale-1"),
      recommending: Recommendation(
        output: "ok",
        by:,
        explanation: RuleFired("scale"),
        signals: [fact.set(score(), value)],
        reads: [],
      ),
    ),
  )
}

fn keys(prefix: String, count: Int) -> List(String) {
  list.map(numbers(1, count), fn(n) { prefix <> "-" <> int.to_string(n) })
}

fn numbers(from: Int, to: Int) -> List(Int) {
  list.reverse(count_up(from, to, []))
}

fn count_up(from: Int, to: Int, so_far: List(Int)) -> List(Int) {
  case from > to {
    True -> so_far
    False -> count_up(from + 1, to, [from, ..so_far])
  }
}

fn shares(items: List(a), processes: Int) -> List(List(a)) {
  let size = int.max(1, { list.length(items) + processes - 1 } / processes)
  list.sized_chunk(items, size)
}

fn all_ok(
  results: List(Result(Result(Nil, String), String)),
) -> Result(Nil, String) {
  list.try_each(results, fn(r) { result.flatten(r) })
}

fn count(target: Target(tx), table: String) -> Result(Int, String) {
  stress.transaction(target, target.rows(_, table)) |> result.map(list.length)
}

fn expect(holds: Bool, otherwise: String) -> Result(Nil, String) {
  case holds {
    True -> Ok(Nil)
    False -> Error(otherwise)
  }
}

/// Microseconds on a clock that only moves forward.
@external(erlang, "decisions_otp_ffi", "monotonic_us")
pub fn monotonic_us() -> Int

fn timed(body: fn() -> Result(a, String)) -> Result(#(a, Int), String) {
  let started = monotonic_us()
  use value <- result.map(body())
  #(value, monotonic_us() - started)
}

/// H1. `count` recommendations the policy proceeds, made by `processes`
/// processes. Returns the microseconds it took.
pub fn h1(
  target: Target(tx),
  count count_: Int,
  processes processes: Int,
) -> Result(Int, String) {
  let desk = desk(target, "scale.auto", None, proceeding())
  use #(Nil, us) <- result.try(
    timed(fn() {
      replay.map(shares(keys("k", count_), processes), processes, fn(share) {
        list.try_each(share, fn(key) {
          within(target, recommend(desk, _, key, Rules("rules", "1"), 1.0))
        })
      })
      |> all_ok
    }),
  )
  use effects <- result.try(count(target, "scale.auto"))
  use Nil <- result.try(expect(
    effects == count_,
    int.to_string(effects) <> " effects",
  ))
  Ok(us)
}

/// What H2 measured.
pub type QueueNumbers {
  QueueNumbers(page_us: Int, median_us: Int, p95_us: Int, total_us: Int)
}

/// H2. `count` occurrences wait for `support`. The time to read a queue
/// page of 50 (the mean of 100 reads), then open and decide every one
/// from `validators` processes: each verdict's latency and the total.
pub fn h2(
  target: Target(tx),
  count count_: Int,
  validators validators: Int,
) -> Result(QueueNumbers, String) {
  let desk = desk(target, "scale.asked", None, asking("support"))
  let all = keys("w", count_)
  use Nil <- result.try(
    replay.map(shares(all, 8), 8, fn(share) {
      list.try_each(share, fn(key) {
        within(target, recommend(desk, _, key, Rules("rules", "1"), 0.5))
      })
    })
    |> all_ok,
  )
  use #(Nil, page_total) <- result.try(
    timed(fn() {
      list.try_each(numbers(1, 100), fn(_) {
        use page <- result.try(target.queue("support", 50))
        expect(
          list.length(page) == 50,
          "a page of " <> int.to_string(list.length(page)),
        )
      })
    }),
  )
  use #(latencies, total) <- result.try(
    timed(fn() {
      replay.map(
        list.index_map(shares(all, validators), fn(share, n) { #(n, share) }),
        validators,
        fn(pair) {
          let #(n, share) = pair
          let validator = Validator("v" <> int.to_string(n), ["support"])
          list.try_map(share, fn(key) {
            let started = monotonic_us()
            use Nil <- result.map(
              within(target, fn(tx) {
                use card <- result.try(
                  decisions.open(
                    desk,
                    tx,
                    occurrence: key,
                    by: validator,
                    latest: fn(ref) { ref.revision },
                  ),
                )
                decisions.decide(desk, tx, card, Approve)
              }),
            )
            monotonic_us() - started
          })
        },
      )
      |> list.try_map(result.flatten)
      |> result.map(list.flatten)
    }),
  )
  let sorted = list.sort(latencies, int.compare)
  use effects <- result.try(count(target, "scale.asked"))
  use Nil <- result.try(expect(
    effects == count_,
    int.to_string(effects) <> " effects",
  ))
  Ok(QueueNumbers(
    page_us: page_total / 100,
    median_us: nth(sorted, 50),
    p95_us: nth(sorted, 95),
    total_us: total,
  ))
}

fn nth(sorted: List(Int), percentile: Int) -> Int {
  let index = { list.length(sorted) - 1 } * percentile / 100
  list.drop(sorted, index) |> list.first |> result.unwrap(0)
}

/// H3. One occurrence with `entries` entries (a recommendation, the
/// policy's answer, a release, and assessments): the mean time to load
/// and fold it, over 20 reads.
pub fn h3(target: Target(tx), entries: Int) -> Result(Int, String) {
  let desk = desk(target, "scale.long", None, proceeding())
  let key = "long-" <> int.to_string(entries)
  use Nil <- result.try(
    within(target, recommend(desk, _, key, Rules("rules", "1"), 1.0)),
  )
  use Nil <- result.try(
    list.try_each(numbers(4, entries), fn(n) {
      within(target, decisions.assess(
        desk,
        _,
        occurrence: key,
        finding: Assessment(
          finding: Right,
          evidence: Ref("audit", int.to_string(n), "1"),
          source: "audit",
          known_at: target.backlog.now(),
        ),
      ))
    }),
  )
  use #(Nil, us) <- result.try(
    timed(fn() {
      list.try_each(numbers(1, 20), fn(_) {
        use known <- result.try(
          stress.transaction(target, fn(tx) {
            decisions.read(desk, tx, occurrence: key)
            |> result.map_error(decisions.describe)
          }),
        )
        expect(
          list.length(known.entries) == int.max(entries, 3),
          int.to_string(list.length(known.entries)) <> " entries",
        )
      })
    }),
  )
  Ok(us / 20)
}

/// H4. `count` occurrences wait about one subject; the superseding event
/// arrives. Returns the microseconds of that one transaction.
pub fn h4(target: Target(tx), count count_: Int) -> Result(Int, String) {
  let desk = desk(target, "scale.superseded", None, asking("finance"))
  use Nil <- result.try(
    within(target, fn(tx) {
      list.try_each(keys("s", count_), fn(key) {
        recommend(desk, tx, key, Rules("rules", "1"), 0.5)
        |> result.replace(Nil)
      })
    }),
  )
  use #(Nil, us) <- result.try(
    timed(fn() {
      stress.transaction(target, fn(tx) {
        use done <- result.try(
          decisions.happened(desk, tx, "superseded", about: ana)
          |> result.map_error(decisions.describe),
        )
        expect(
          list.length(done.expired) == count_,
          int.to_string(list.length(done.expired)) <> " expired",
        )
      })
    }),
  )
  Ok(us)
}

/// Beside H4: `count` occurrences wait, one in ten about one subject.
/// The mean time of the port's `waiting` for that subject, over 100
/// calls, each a transaction of its own.
pub fn waiting(target: Target(tx), count count_: Int) -> Result(Int, String) {
  let desk = desk(target, "scale.waiting", None, asking("finance"))
  let name = "scale.waiting"
  use Nil <- result.try(
    replay.map(shares(numbers(1, count_), 8), 8, fn(share) {
      list.try_each(share, fn(n) {
        let about = case n % 10 {
          0 -> ana
          _ -> Subject(kind: "person", id: "other-" <> int.to_string(n))
        }
        within(target, fn(tx) {
          decisions.recommend_once(
            desk,
            tx,
            key: "wt-" <> int.to_string(n),
            proposal: decisions.proposal(
              trigger: Trigger(kind: "scale", id: int.to_string(n)),
              about:,
              context: Manifest(refs: [], renderer: "scale-1"),
              recommending: Recommendation(
                output: "ok",
                by: Rules("rules", "1"),
                explanation: RuleFired("scale"),
                signals: [fact.set(score(), 0.5)],
                reads: [],
              ),
            ),
          )
        })
      })
    })
    |> all_ok,
  )
  use #(Nil, us) <- result.try(
    timed(fn() {
      list.try_each(numbers(1, 100), fn(_) {
        use ids <- result.try(
          stress.transaction(target, fn(tx) {
            target.adapter.port.waiting(tx, name, ana)
            |> result.map_error(store.describe)
          }),
        )
        expect(
          list.length(ids) == count_ / 10,
          int.to_string(list.length(ids)) <> " waiting",
        )
      })
    }),
  )
  Ok(us / 100)
}

/// H5. `count` holds end in the same second; one runtime (one sweeper)
/// releases them. Returns the microseconds from starting the runtime to
/// the last release.
pub fn h5(target: Target(tx), count count_: Int) -> Result(Int, String) {
  let desk = desk(target, "scale.held", Some(duration.minutes(1)), proceeding())
  use Nil <- result.try(
    replay.map(shares(keys("h", count_), 8), 8, fn(share) {
      list.try_each(share, fn(key) {
        within(target, recommend(desk, _, key, Person("bia"), 1.0))
      })
    })
    |> all_ok,
  )
  target.advance(duration.minutes(2))
  let config =
    runtime.Config(
      ..runtime.config(
        target.backlog,
        points: [runtime.point(desk, settled: runtime.nothing_follows)],
        work: fn(_) { Ok(Nil) },
      ),
      poll: duration.milliseconds(1),
      batch: 500,
    )
  let started = monotonic_us()
  use tree <- result.try(start_runtime(config))
  let done = wait(fn() { count(target, "scale.held") == Ok(count_) }, 120_000)
  let us = monotonic_us() - started
  stop(tree)
  use Nil <- result.try(expect(done, "the holds were not all released"))
  Ok(us)
}

fn start_runtime(config: runtime.Config(tx)) -> Result(process.Pid, String) {
  let reply = process.new_subject()
  process.spawn_unlinked(fn() {
    case runtime.start(config) {
      Ok(started) -> {
        process.send(reply, Ok(started.pid))
        process.sleep_forever()
      }
      Error(error) -> process.send(reply, Error(string.inspect(error)))
    }
  })
  process.receive(reply, 5000)
  |> result.unwrap(Error("the runtime did not start"))
}

fn stop(pid: process.Pid) -> Nil {
  process.kill(pid)
  process.sleep(10)
}

fn wait(condition: fn() -> Bool, ms: Int) -> Bool {
  case condition(), ms <= 0 {
    True, _ -> True
    False, True -> False
    False, False -> {
      process.sleep(1)
      wait(condition, ms - 1)
    }
  }
}

/// What H6 measured: microseconds for one process and for `across`, and
/// whether the two tallies were equal.
pub type ReplayNumbers {
  ReplayNumbers(one_us: Int, many_us: Int, across: Int, same: Bool)
}

/// H6. Replay `count` examples through a pure candidate on one process,
/// then on `across`.
pub fn h6(
  target: Target(tx),
  count count_: Int,
  across across: Int,
) -> Result(ReplayNumbers, String) {
  let desk = desk(target, "scale.replayed", None, proceeding())
  let all = keys("e", count_)
  use Nil <- result.try(
    replay.map(shares(all, 8), 8, fn(share) {
      list.try_each(share, fn(key) {
        within(target, recommend(desk, _, key, Classifier("c", "1"), 1.0))
      })
    })
    |> all_ok,
  )
  let archive =
    Archive(
      render: fn(_) { Ok("prompt") },
      reads: fn(_) { [] },
      content: fn(ref) { Ok(ref.id) },
    )
  let now = target.backlog.now()
  use examples <- result.try(
    list.try_map(all, fn(key) {
      use known <- result.try(
        stress.transaction(target, fn(tx) {
          decisions.read(desk, tx, occurrence: key)
          |> result.map_error(decisions.describe)
        }),
      )
      learning.example(known, as_of: now, from: archive)
      |> result.map_error(string.inspect)
    }),
  )
  let candidate =
    model.new(fn(context: Manifest, _) {
      let answer = case context.refs {
        [Ref(id:, ..)] ->
          case string.ends_with(id, "7") {
            True -> "spam"
            False -> "ok"
          }
        _ -> "ok"
      }
      Ok(
        Recommendation(answer, Rules("candidate", "1"), RuleFired("r"), [], []),
      )
    })
  let same = fn(a, b) { a == b }
  use #(one, one_us) <- result.try(
    timed(fn() { Ok(learning.replay(examples, candidate, same:)) }),
  )
  use #(many, many_us) <- result.try(
    timed(fn() { Ok(replay.replay(examples, candidate, same:, across:)) }),
  )
  Ok(ReplayNumbers(one_us:, many_us:, across:, same: one == many))
}

/// What use case 12 measured.
pub type ModerationNumbers {
  ModerationNumbers(
    total_us: Int,
    proceeded: Int,
    waiting: Int,
    sampled: Int,
    agreement_before: #(Int, Int),
    agreement_after: #(Int, Int),
    accuracy_after: #(Int, Int),
  )
}

/// Use case 12. `count` posts classified by `processes` processes: the
/// policy proceeds at a score of 0.9 or above, sampling 2 %, and asks
/// `support` otherwise. One in ten scores below. Support approves the
/// waiting ones; then 50 appeals arrive, 30 of them "wrong". `sampled`
/// counts the released occurrences whose head is pending review.
pub fn moderation(
  target: Target(tx),
  count count_: Int,
  processes processes: Int,
) -> Result(ModerationNumbers, String) {
  let desk = desk(target, "scale.moderation", None, scoring(2))
  let posts = numbers(1, count_)
  use #(Nil, us) <- result.try(
    timed(fn() {
      replay.map(shares(posts, processes), processes, fn(share) {
        list.try_each(share, fn(n) {
          let value = case n % 10 {
            0 -> 0.5
            _ -> 0.95
          }
          within(target, recommend(
            desk,
            _,
            "post-" <> int.to_string(n),
            Classifier("moderation", "v1"),
            value,
          ))
        })
      })
      |> all_ok
    }),
  )
  use proceeded <- result.try(count(target, "scale.moderation"))
  use waiting <- result.try(target.queue("support", count_))
  use known <- result.try(read_all(target, desk, posts))
  let sampled = list.count(known, fn(o) { o.sampled })
  let dora = Validator("dora", ["support"])
  use Nil <- result.try(
    list.try_each(waiting, fn(id) {
      within(target, fn(tx) {
        use card <- result.try(
          decisions.open(desk, tx, occurrence: id, by: dora, latest: fn(ref) {
            ref.revision
          }),
        )
        decisions.decide(desk, tx, card, Approve)
      })
    }),
  )
  use before <- result.try(
    read_all(target, desk, posts)
    |> result.map(fn(k) { learning.total(learning.tally(k)) }),
  )
  use Nil <- result.try(
    list.try_each(numbers(1, 50), fn(n) {
      let id = "post-" <> int.to_string(n * 10)
      within(target, decisions.assess(
        desk,
        _,
        occurrence: id,
        finding: Assessment(
          finding: case n <= 30 {
            True -> Wrong(None)
            False -> Right
          },
          evidence: Ref("appeal", id, "1"),
          source: "appeals",
          known_at: target.backlog.now(),
        ),
      ))
    }),
  )
  use after <- result.try(
    read_all(target, desk, posts)
    |> result.map(fn(k) { learning.total(learning.tally(k)) }),
  )
  Ok(
    ModerationNumbers(
      total_us: us,
      proceeded:,
      waiting: list.length(waiting),
      sampled:,
      agreement_before: #(before.agreed, before.judged),
      agreement_after: #(after.agreed, after.judged),
      accuracy_after: #(after.right, after.assessed),
    ),
  )
}

fn read_all(
  target: Target(tx),
  desk: decisions.Desk(String, tx),
  posts: List(Int),
) -> Result(List(occurrence.Occurrence(String)), String) {
  list.try_map(posts, fn(n) {
    use tx <- stress.transaction(target)
    decisions.read(desk, tx, occurrence: "post-" <> int.to_string(n))
    |> result.map_error(decisions.describe)
  })
}

/// A policy this module writes as a literal, which is well formed.
fn well_formed(
  version version: Int,
  rules rules: List(policy.Rule),
  otherwise otherwise: policy.Eligible,
) -> Policy {
  let assert Ok(made) = policy.new(version:, rules:, otherwise:)
  made
}
