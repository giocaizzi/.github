#!/usr/bin/env bash
# Tests scripts/sync.sh pieces that decide pass, drift or a broken run, without GitHub:
# - local_ok: where a `./` ref may point (sourced helpers);
# - a missing checker lock is a crash, so nothing passes and the run is broken;
# - an API failure and a truncated repo tree stop an audit with exit 2, never drift (tests/fake-gh/gh).
# shellcheck disable=SC2154,SC2317,SC2329 # pin_cache and broken come from the sourced sync.sh; t() calls not_ok
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
t() { if "$@"; then :; else echo "FAIL: $*"; fail=1; fi; }

# shellcheck source=/dev/null # sync.sh returns after its helpers when sourced
source scripts/sync.sh
trap 'rm -f "$pin_cache" "$broken" "$broken.last"' EXIT # not sync.sh's exit mapping: this script's exit code is its own
tree=$'100644 a1 dir/action.yml\n120000 a2 link\n120000 a3 linked/action.yml\n100644 a4 .github/workflows/r.yml\n100644 a5 action.yaml\n100644 a6 we\\ird/action.yml'
t local_ok "$tree" ./dir
t local_ok "$tree" ./dir/
t local_ok "$tree" ./.github/workflows/r.yml
t local_ok "$tree" ./                       # the repo root's action.yaml
t local_ok "$tree" './we\ird'               # passed through ENVIRON, not unescaped by awk -v
not_ok() { ! local_ok "$@"; }
t not_ok "$tree" ./link                     # a symlink to a directory is not scanned
t not_ok "$tree" ./linked                   # nor an action.yml that is a symlink
t not_ok "$tree" ./missing
t not_ok "100644 a1 dir/action.yml" ./      # no action.yml at the root

# a missing lock file: a wf_parsed finding and a broken record
tmp=$(mktemp -d); mkdir "$tmp/scripts"; cp scripts/workflow.py "$tmp/scripts/"
out=$(DIR=$tmp wf_out < standard/workflows/pr-title.yml 2>/dev/null)
t grep -q '^wf_parsed' <<<"$out"
t grep -q 'workflow.py failed' "$broken"
: > "$broken"; rm -rf "$tmp"

# a broken run exits 2 (audit.yml then fails instead of filing drift)
# shellcheck disable=SC2069 # stderr to the capture, stdout dropped, on purpose
audit() { PATH="$PWD/tests/fake-gh:$PATH" GH_TOKEN=x FAKE_GH=$1 OWNER=o scripts/sync.sh audit r 2>&1 >/dev/null; } # keep stderr only
rc=0; err=$(audit fail) || rc=$?; t test "$rc" = 2; t grep -q 'HTTP 502' <<<"$err"
rc=0; err=$(audit truncated) || rc=$?; t test "$rc" = 2; t grep -q 'tree of r truncated' <<<"$err"

[ "$fail" = 0 ] && echo "sync.sh helpers and exit codes: ok"
exit "$fail"
