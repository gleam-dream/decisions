//// The scale run: condition H and use case 12 against the process-safe
//// in-memory store, each on a fresh store. It prints the load and the
//// machine with every number. The workloads are
//// `decisions_otp/scale`'s, which another store can run unchanged.

import decisions_otp/scale
import decisions_otp/store
import decisions_otp/stress.{type Target}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/timestamp

@external(erlang, "decisions_otp_bench_ffi", "machine")
fn machine() -> String

@external(erlang, "decisions_otp_ffi", "quiet")
fn quiet() -> Nil

fn fresh() -> Target(store.Tx) {
  let assert Ok(target) = stress.in_memory(store.defaults())
  target
}

/// A target and the store under it.
fn fresh_store() -> #(store.Store, Target(store.Tx)) {
  let assert Ok(s) = store.start(store.defaults())
  #(s, stress.over_store(s, store.defaults()))
}

fn export_all(s: store.Store, after: Option(store.Cursor), count: Int) -> Int {
  let page = store.occurrences_of(s, "scale.auto", after:, limit: 100)
  let count = count + list.length(page.ids)
  case page.next {
    Some(next) -> export_all(s, Some(next), count)
    None -> count
  }
}

fn export_settled(
  s: store.Store,
  after: Option(store.Cursor),
  count: Int,
) -> Int {
  let page =
    store.settled_since(
      s,
      "scale.auto",
      since: timestamp.from_unix_seconds(0),
      after:,
      limit: 100,
    )
  let count = count + list.length(page.ids)
  case page.next {
    Some(next) -> export_settled(s, Some(next), count)
    None -> count
  }
}

fn done(target: Target(store.Tx)) -> Nil {
  target.adapter.cleanup()
}

fn ms(us: Int) -> String {
  int.to_string(us / 1000)
  <> "."
  <> string.pad_start(int.to_string(us % 1000 / 10), 2, "0")
  <> " ms"
}

fn per_second(count: Int, us: Int) -> String {
  int.to_string(count * 1_000_000 / int.max(us, 1)) <> "/s"
}

pub fn main() -> Nil {
  quiet()
  io.println("decisions_otp scale run, in-memory store")
  io.println("machine: " <> machine())
  io.println("")

  io.println("H1. 10 000 recommendations the policy proceeds")
  list.each([1, 4, 16], fn(processes) {
    let target = fresh()
    let assert Ok(us) = scale.h1(target, count: 10_000, processes:)
    done(target)
    io.println(
      "  "
      <> string.pad_start(int.to_string(processes), 2, " ")
      <> " processes: "
      <> ms(us)
      <> ", "
      <> per_second(10_000, us),
    )
  })

  io.println("H2. 10 000 waiting for one decision set")
  let target = fresh()
  let assert Ok(queue) = scale.h2(target, count: 10_000, validators: 16)
  done(target)
  io.println("  a queue page of 50: " <> int.to_string(queue.page_us) <> " µs")
  io.println(
    "  open and decide from 16 validator processes: median "
    <> ms(queue.median_us)
    <> ", 95th percentile "
    <> ms(queue.p95_us)
    <> ", "
    <> per_second(10_000, queue.total_us)
    <> " verdicts",
  )

  io.println("H3. loading one occurrence (load, decode, fold), mean of 20")
  list.each([10, 100, 1000], fn(entries) {
    let target = fresh()
    let assert Ok(us) = scale.h3(target, entries)
    done(target)
    io.println(
      "  "
      <> string.pad_start(int.to_string(entries), 4, " ")
      <> " entries: "
      <> ms(us),
    )
  })

  io.println("H4. 1 000 waiting about one subject; the superseding event")
  let target = fresh()
  let assert Ok(us) = scale.h4(target, count: 1000)
  done(target)
  io.println("  one transaction: " <> ms(us))

  io.println(
    "Beside H4. 10 000 waiting, 1 000 about one subject: the port's waiting",
  )
  let target = fresh()
  let assert Ok(us) = scale.waiting(target, count: 10_000)
  done(target)
  io.println("  one call: " <> int.to_string(us) <> " µs")

  io.println("H5. 5 000 holds end in the same second; one sweeper")
  let target = fresh()
  let assert Ok(us) = scale.h5(target, count: 5000)
  done(target)
  io.println("  all released after " <> ms(us) <> ", " <> per_second(5000, us))

  io.println("H6. replay of 10 000 examples through a pure candidate")
  let target = fresh()
  let assert Ok(replayed) = scale.h6(target, count: 10_000, across: 12)
  done(target)
  io.println(
    "  1 process: "
    <> ms(replayed.one_us)
    <> "; "
    <> int.to_string(replayed.across)
    <> " processes: "
    <> ms(replayed.many_us)
    <> "; same tally: "
    <> string.inspect(replayed.same),
  )

  io.println("Export. 10 000 occurrences of one point, read in pages of 100")
  let #(s, target) = fresh_store()
  let assert Ok(_) = scale.h1(target, count: 10_000, processes: 8)
  let started = scale.monotonic_us()
  let read = export_all(s, None, 0)
  let all_us = scale.monotonic_us() - started
  let started = scale.monotonic_us()
  let settled = export_settled(s, None, 0)
  let settled_us = scale.monotonic_us() - started
  done(target)
  io.println(
    "  occurrences_of: "
    <> int.to_string(read)
    <> " in "
    <> ms(all_us)
    <> "; settled_since: "
    <> int.to_string(settled)
    <> " in "
    <> ms(settled_us),
  )

  io.println(
    "Use case 12. 10 000 posts, 8 processes, proceed at 0.9 sampling 2 %",
  )
  let target = fresh()
  let assert Ok(m) = scale.moderation(target, count: 10_000, processes: 8)
  done(target)
  io.println(
    "  "
    <> ms(m.total_us)
    <> "; "
    <> int.to_string(m.proceeded)
    <> " proceeded, "
    <> int.to_string(m.waiting)
    <> " waited, "
    <> int.to_string(m.sampled)
    <> " sampled",
  )
  io.println(
    "  agreement before the appeals "
    <> string.inspect(m.agreement_before)
    <> ", after "
    <> string.inspect(m.agreement_after)
    <> "; accuracy after "
    <> string.inspect(m.accuracy_after),
  )
}
