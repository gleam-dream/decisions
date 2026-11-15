#!/usr/bin/env bash
# Compiles and tests every package in the repository, in the Nix dev shell:
#
#   .                              the core package: build, gleam test
#   examples/usage                 build, gleam test
#   integrations/decisions_otp     build, gleam test
#   integrations/decisions_postgres  build, scripts/test-postgres.sh
#   scripts/check_negative.sh      compiler-negative fixtures still fail
#   scripts/check_javascript.sh    the core on the JavaScript target
#
# Each package is built with --warnings-as-errors, and its Erlang sources
# under src/ and test/ are compiled with `erlc -Werror`. It does not run
# formatting or design-layer validation; CI runs those as separate steps.
#
# A part that does not exist yet (no gleam.toml, or no script) is skipped
# with a SKIP line. With --require-all, a missing part fails the run instead;
# CI uses --require-all.
#
# Usage: nix develop --command bash scripts/test.sh [--require-all]
set -euo pipefail
cd "$(dirname "$0")/.."

require_all=0
case "${1:-}" in
"") ;;
--require-all) require_all=1 ;;
*)
  echo "usage: scripts/test.sh [--require-all]" >&2
  exit 2
  ;;
esac

skipped=()
skip() {
  echo "SKIP: $1"
  skipped+=("$1")
}

native_output="$(mktemp -d)"
trap 'rm -rf "$native_output"' EXIT

for package in . examples/usage integrations/decisions_otp integrations/decisions_postgres; do
  if [[ ! -f "$package/gleam.toml" ]]; then
    skip "$package does not exist yet (no $package/gleam.toml)"
    continue
  fi
  echo "== $package =="
  (
    cd "$package"
    gleam build --warnings-as-errors
    includes=()
    for directory in build/dev/erlang/*/include; do
      if [[ -d $directory ]]; then includes+=(-I "$directory"); fi
    done
    sources=()
    for directory in src test; do
      if [[ -d $directory ]]; then sources+=("$directory"); fi
    done
    if [[ ${#sources[@]} -gt 0 ]]; then
      ERL_LIBS="$PWD/build/dev/erlang" find "${sources[@]}" -name '*.erl' \
        -exec erlc -Werror ${includes[@]+"${includes[@]}"} -o "$native_output" {} +
    fi
    case "$package" in
    integrations/decisions_postgres) ;;
    *) gleam test ;;
    esac
  )
  if [[ $package == integrations/decisions_postgres ]]; then
    bash scripts/test-postgres.sh
  fi
done

for script in scripts/check_negative.sh scripts/check_javascript.sh; do
  if [[ ! -f $script ]]; then
    skip "$script does not exist yet"
    continue
  fi
  echo "== $script =="
  bash "$script"
done

if [[ ${#skipped[@]} -gt 0 ]]; then
  echo
  echo "Skipped ${#skipped[@]} part(s) that do not exist yet:"
  printf '  %s\n' "${skipped[@]}"
  if [[ $require_all == 1 ]]; then
    echo "FAIL: --require-all was given and parts are missing" >&2
    exit 1
  fi
  echo "The parts above were NOT tested."
else
  echo
  echo "All packages and checks passed."
fi
