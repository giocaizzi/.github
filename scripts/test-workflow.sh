#!/usr/bin/env bash
# Tests the workflow checker and its text modes:
# - scripts/workflow.py (the pinned YAML parser, via uv): the standard and own workflows have no finding, and each
#   tests/workflows/<name>.yml prints <name>.out;
# - scripts/workflow.awk (text modes) under every awk on PATH (awk, gawk, mawk, busybox awk; AWKS="a,b" overrides):
#   <name>.yml prints <name>.norm and <name>.subst where present.
set -euo pipefail
cd "$(dirname "$0")/.."
check() { uv run --quiet --script --locked scripts/workflow.py; }
fail=0
for f in standard/workflows/*.yml .github/workflows/*.yml; do
  out=$(check < "$f" | grep -v '^pin	' || true)
  [ -z "$out" ] || { echo "$f: $out"; fail=1; }
done
for f in tests/workflows/*.yml; do
  check < "$f" | diff -u "${f%.yml}.out" - || { echo "workflow.py: $f"; fail=1; }
done
[ "$fail" = 0 ] && echo "workflow.py fixtures: ok"

reps='actions/checkout=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7.1.0'
if [ -n "${AWKS:-}" ]; then IFS=, read -r -a awks <<<"$AWKS"
else
  awks=()
  for a in awk gawk mawk; do command -v "$a" >/dev/null && awks+=("$a"); done
  command -v busybox >/dev/null && awks+=("busybox awk")
fi
for a in "${awks[@]}"; do
  read -r -a cmd <<<"$a"; before=$fail
  for f in tests/workflows/*.yml; do
    b=${f%.yml}
    for m in norm subst; do
      [ -f "$b.$m" ] || continue
      "${cmd[@]}" -v mode="$m" -v reps="$reps" -f scripts/workflow.awk "$f" | diff -u "$b.$m" - || { echo "$a: $f ($m)"; fail=1; }
    done
  done
  [ "$fail" = "$before" ] && echo "workflow.awk modes: $a ok"
done
exit $fail
