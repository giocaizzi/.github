#!/usr/bin/env bash
# Tests the tooling inventory (scripts/tooling.py, run through uv from its hashed lock):
# - each tests/tooling/<case>/ with an `args` file runs `collect` on its tree and the normalised output (jq -S) must
#   equal expected.json. The tree is <case>/repo, or tests/tooling/<name>/repo when the case has a `uses` file;
#   the config is <case>/config.json, or the path in <case>/config.path, else tests/tooling/config-empty.json.
#   A case with an `exit` file expects that exit code (2: a config error) and prints nothing on stdout;
# - `wanted` filters tests/tooling/wanted.in to wanted.out;
# - the shipped standard/tooling.json lists exactly the tool ids `collect` prints.
# UPDATE=1 rewrites every expected.json from the current output (review the diff before committing).
set -euo pipefail
cd "$(dirname "$0")/.."
# `--locked` runs unhashed when the lock is missing: the lock must be there
test -f scripts/tooling.py.lock || { echo "scripts/tooling.py.lock missing"; exit 1; }
run() { uv run --quiet --script --locked scripts/tooling.py "$@"; }
fail=0
for dir in tests/tooling/*/; do
  case=${dir%/}
  [ -f "$case/args" ] || continue
  tree=$case/repo
  [ -f "$case/uses" ] && tree=tests/tooling/$(<"$case/uses")/repo
  cfg=tests/tooling/config-empty.json
  [ -f "$case/config.json" ] && cfg=$case/config.json
  [ -f "$case/config.path" ] && cfg=$(<"$case/config.path")
  read -r -a args <<<"$(<"$case/args")"
  want=0
  [ -f "$case/exit" ] && want=$(<"$case/exit")
  got=0
  out=$(run collect "${args[@]}" --config "$cfg" "$tree" 2>/dev/null) || got=$?
  if [ "$got" != "$want" ]; then echo "$case: exit $got, want $want"; fail=1; continue; fi
  if [ "$want" != 0 ]; then
    [ -z "$out" ] || { echo "$case: stdout on a config error"; fail=1; }
    continue
  fi
  [ -z "${UPDATE:-}" ] || jq -S . <<<"$out" >"$case/expected.json"
  diff -u <(jq -S . "$case/expected.json") <(jq -S . <<<"$out") || { echo "tooling.py: $case"; fail=1; }
done
[ "$fail" = 0 ] && echo "tooling.py cases: ok"

run wanted <tests/tooling/wanted.in | diff -u tests/tooling/wanted.out - || { echo "tooling.py wanted"; fail=1; }

# the shipped config restates the defaults: it must not change any cell
diff -u <(jq -S . tests/tooling/python-good/expected.json) <(jq -S . tests/tooling/shipped-config/expected.json) \
  || { echo "standard/tooling.json differs from the built-in defaults"; fail=1; }
diff -u <(jq -S 'keys' tests/tooling/python-good/expected.json) <(jq -S '.checks | keys' standard/tooling.json) \
  || { echo "standard/tooling.json does not list every tool id"; fail=1; }
exit $fail
