#!/usr/bin/env bash
# Tests scripts/workflow.awk under every awk on PATH (awk, gawk, mawk, busybox awk; AWKS="..." overrides):
# the standard and own workflows pass, and each tests/workflows/<name>.yml prints <name>.out
# (plus <name>.pins, .norm, .subst for the other modes, where present).
set -euo pipefail
cd "$(dirname "$0")/.."
reps='actions/checkout=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7.1.0'
if [ -n "${AWKS:-}" ]; then IFS=, read -r -a awks <<<"$AWKS"
else
  awks=()
  for a in awk gawk mawk; do command -v "$a" >/dev/null && awks+=("$a"); done
  command -v busybox >/dev/null && awks+=("busybox awk")
fi
fail=0
for a in "${awks[@]}"; do
  read -r -a cmd <<<"$a"; before=$fail
  for f in standard/workflows/*.yml .github/workflows/*.yml; do
    out=$("${cmd[@]}" -f scripts/workflow.awk "$f")
    [ -z "$out" ] || { echo "$a: $f: $out"; fail=1; }
  done
  for f in tests/workflows/*.yml; do
    b=${f%.yml}
    "${cmd[@]}" -f scripts/workflow.awk "$f" | diff -u "$b.out" - || { echo "$a: $f"; fail=1; }
    for m in pins norm subst; do
      [ -f "$b.$m" ] || continue
      "${cmd[@]}" -v mode="$m" -v reps="$reps" -f scripts/workflow.awk "$f" | diff -u "$b.$m" - || { echo "$a: $f ($m)"; fail=1; }
    done
  done
  [ "$fail" = "$before" ] && echo "workflow.awk fixtures: $a ok"
done
exit $fail
