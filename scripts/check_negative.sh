#!/usr/bin/env bash
# Checks that the compiler-negative fixtures under fixtures/negative/ fail to
# compile with their expected diagnostics, from an external consumer's point
# of view: each fixture is copied into examples/usage/src (a package that
# imports only public modules of decisions) and checked with `gleam check`.
#
# The positive controls under fixtures/negative/controls/ are the same shapes
# written correctly. Each must compile, which shows that its negative fixture
# fails for the reason its .expect file names and not for an unrelated
# mistake.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$ROOT/fixtures/negative"
CONTROLS_DIR="$FIXTURES_DIR/controls"
CONSUMER_DIR="$ROOT/examples/usage"
PROBE_FILE="$CONSUMER_DIR/src/negative_probe.gleam"

cleanup() {
  rm -f "$PROBE_FILE"
}
trap cleanup EXIT

probe() {
  cp "$1" "$PROBE_FILE"
  set +e
  output="$(cd "$CONSUMER_DIR" && gleam check 2>&1)"
  status=$?
  set -e
  rm -f "$PROBE_FILE"
}

if [ -z "$(ls -A "$FIXTURES_DIR"/*.gleam 2>/dev/null)" ]; then
  echo "FAIL: no negative fixtures in $FIXTURES_DIR" >&2
  exit 1
fi
if [ -z "$(ls -A "$CONTROLS_DIR"/*.gleam 2>/dev/null)" ]; then
  echo "FAIL: no positive controls in $CONTROLS_DIR" >&2
  exit 1
fi

# The consumer itself must compile, or every fixture would fail trivially.
cleanup
if ! (cd "$CONSUMER_DIR" && gleam check >/dev/null 2>&1); then
  echo "FAIL: examples/usage does not compile on its own" >&2
  exit 1
fi

echo "== positive controls (must compile) =="
controls=0
for fixture in "$CONTROLS_DIR"/*.gleam; do
  name="$(basename "$fixture" .gleam)"
  probe "$fixture"
  if [ "$status" -ne 0 ]; then
    echo "FAIL: control $name did not compile:" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "PASS: control $name compiled"
  controls=$((controls + 1))
done

echo
echo "== negative fixtures (must fail with their expected diagnostic) =="
passed=0
for fixture in "$FIXTURES_DIR"/*.gleam; do
  name="$(basename "$fixture" .gleam)"
  expect_file="$FIXTURES_DIR/$name.expect"
  if [ ! -f "$expect_file" ]; then
    echo "FAIL: missing $name.expect" >&2
    exit 1
  fi
  probe "$fixture"
  if [ "$status" -eq 0 ]; then
    echo "FAIL: $name compiled but must not" >&2
    exit 1
  fi
  while IFS= read -r fragment; do
    case "$fragment" in
    "" | "#"*) continue ;;
    esac
    if ! grep -qF -- "$fragment" <<<"$output"; then
      echo "FAIL: $name did not report: $fragment" >&2
      echo "$output" >&2
      exit 1
    fi
  done <"$expect_file"
  echo "PASS: $name refused"
  passed=$((passed + 1))
done

echo
echo "$controls controls compiled; $passed negative fixtures refused."
