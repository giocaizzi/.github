#!/usr/bin/env bash
# Tests scripts/report.py: each tests/report/<case>.json renders to <case>.md (fixed date and run URL);
# REGEN=1 rewrites the expected files. A generated oversized input must fit the issue limit with its tooling dropped.
set -euo pipefail
cd "$(dirname "$0")/.."
report() { uv run --quiet --script scripts/report.py --date 2026-01-05 --run-url https://github.com/acme/audit/actions/runs/1; }
fail=0
for f in tests/report/*.json; do
  b=${f%.json}
  if [ "${REGEN:-}" = 1 ]; then report < "$f" > "$b.md"; continue; fi
  report < "$f" | diff -u "$b.md" - || { echo "report.py: $f"; fail=1; }
done

# size cap: 1500 repos with a long drift row each, plus tooling
big=$(mktemp)
trap 'rm -f "$big"' EXIT
jq -n '[range(0; 1500) | {repo: "acme-\(.)", type: "go", released: false, private: false, exempt: [], unknown: 0,
  checks: {wf_pinned: {kind: "standard", pass: false, status: "fail", detail: "ci.yml: actions/checkout@v4 is not pinned by full SHA"}},
  extras: {}, score: {standard: "0/1", typed: "0/0", extras: "0/0"},
  tooling: {uv: {group: "common", value: "0.11.2", expected: "0.11.2", status: "same", severity: "info"}}}]' > "$big"
out=$(report < "$big")
n=${#out}
[ "$n" -le 60000 ] || { echo "report.py: body is $n chars, over 60000"; fail=1; }
grep -q '^\.\.\. [0-9]* more rows in the audit artifact$' <<<"$out" || { echo "report.py: no truncation line"; fail=1; }
grep -q 'Tooling inventory' <<<"$out" && { echo "report.py: tooling kept in an oversized body"; fail=1; }
[ "$fail" = 0 ] && echo "report.py fixtures: ok"
exit $fail
