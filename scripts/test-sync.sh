#!/usr/bin/env bash
# Tests scripts/sync.sh pieces that decide pass, drift or a broken run, without GitHub:
# - local_ok: where a `./` ref may point (sourced helpers);
# - dependabot_ungrouped / dependabot_unprefixed: grouped and ungrouped fixtures (tests/dependabot/);
# - a missing checker lock is a crash, so nothing passes and the run is broken;
# - an API failure and a truncated repo tree stop an audit with exit 2, never drift (tests/fake-gh/gh);
# - the workflow scan (any case, empty stem), unknown vs drift, the tooling inventory glue (stub: tests/fake-gh/tooling-stub.py).
# - the audit's `stale` check passes the standard stale workflow and fails a missing or drifted copy.
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
t local_ok "$tree"$'\n100644 b1 .github/workflows/X.YML' ./.github/workflows/X.YML # scanned in any case
t local_ok "$tree"$'\n100644 b2 .github/workflows/.yml' ./.github/workflows/.yml    # and with an empty stem
not_ok() { ! local_ok "$@"; }
t not_ok "$tree"$'\n100644 b3 docs/x.yml' ./docs/x.yml                          # a regular file the scan never reads
t not_ok "$tree"$'\n100644 b4 .github/workflows/sub/y.yml' ./.github/workflows/sub/y.yml # not a direct child
t not_ok "$tree"$'\n100644 b5 .github/workflows/x.txt' ./.github/workflows/x.txt
t not_ok "$tree" ./link                     # a symlink to a directory is not scanned
t not_ok "$tree" ./linked                   # nor an action.yml that is a symlink
t not_ok "$tree" ./missing
t not_ok "100644 a1 dir/action.yml" ./      # no action.yml at the root

# file_sha: a missing file is empty (gh prints the 404 JSON body on stdout), only a 40-hex sha counts
fsha() { PATH="$PWD/tests/fake-gh:$PATH" OWNER=o FAKE_CONTENTS=${2:-} file_sha a "$1" chore/x; }
t test -z "$(fsha .github/workflows/pr-title.yml)"
t test "$(fsha x.yml 0123456789abcdef0123456789abcdef01234567)" = 0123456789abcdef0123456789abcdef01234567
t test -z "$(fsha x.yml not-a-sha)"

# the dependabot helpers print "<entries> <failing entries>" for each fixture
counts() { t test "$("$1" < "$2")" = "$3"; }
counts dependabot_ungrouped tests/dependabot/grouped.yml "3 0"
counts dependabot_unprefixed tests/dependabot/grouped.yml "3 0"
counts dependabot_ungrouped tests/dependabot/ungrouped.yml "5 4"
counts dependabot_unprefixed tests/dependabot/ungrouped.yml "5 1"
counts dependabot_ungrouped .github/dependabot.yml "1 0"   # this repo's own config meets the standard
counts dependabot_unprefixed .github/dependabot.yml "1 0"
counts dependabot_ungrouped /dev/null "0 0"

# a missing lock file: a wf_parsed finding and a broken record
tmp=$(mktemp -d); mkdir "$tmp/scripts"; cp scripts/workflow.py "$tmp/scripts/"
out=$(DIR=$tmp wf_out < standard/workflows/pr-title.yml 2>/dev/null)
t grep -q '^wf_parsed' <<<"$out"
t grep -q 'workflow.py failed' "$broken"
: > "$broken"; rm -rf "$tmp"

# a broken run exits 2 (audit.yml then fails instead of filing drift)
stub=$PWD/tests/fake-gh/tooling-stub.py
# shellcheck disable=SC2069 # stderr to the capture, stdout dropped, on purpose
audit() { PATH="$PWD/tests/fake-gh:$PATH" GH_TOKEN=x FAKE_GH=$1 OWNER=o TOOLING=$stub scripts/sync.sh audit r 2>&1 >/dev/null; } # keep stderr only
rc=0; err=$(audit fail) || rc=$?; t test "$rc" = 2; t grep -q 'HTTP 502' <<<"$err"
rc=0; err=$(audit truncated) || rc=$?; t test "$rc" = 2; t grep -q 'tree of r truncated' <<<"$err"

# an inherited `finished` must not turn a broken run into drift
rc=0; finished=1 audit fail >/dev/null || rc=$?; t test "$rc" = 2

# a file name with `&`, `\`, `|`, `?` or `#` is checked like any other (it once emptied every finding through sed,
# or fetched another file): the bad workflow fails its checks whatever its name
pinned_fails() { jq -e '.[0].checks.wf_pinned.pass == false' <<<"$2" >/dev/null; } # $1 names the case in a FAIL line
files() { PATH="$PWD/tests/fake-gh:$PATH" GH_TOKEN=x FAKE_GH=files FAKE_PATH=$1 OWNER=o TOOLING=$stub scripts/sync.sh audit --json r 2>/dev/null; }
for p in .github/workflows/bad.yml '.github/workflows/&.yml' '.github/workflows/\n.yml' '.github/workflows/a|b.yml' \
  '.github/workflows/ok?x.yml' '.github/workflows/c#d.yml' '&/action.yml' \
  .github/workflows/.yml .github/workflows/.yaml .github/workflows/X.YML .github/workflows/X.Yaml; do
  rc=0; json=$(files "$p") || rc=$?
  t test "$rc" = 1
  t pinned_fails "$p" "$json" # both bad files hold evil/action@main
done
# a path with a control character (a newline would split it into two lines) is a broken run
rc=0; files $'.github/workflows/a\nb.yml' >/dev/null || rc=$?; t test "$rc" = 2

# unknown is not drift: a null setting or a probe the token cannot read; a real mismatch wins over a null key
# fx runs an audit of repo r with the given env assignments: JSON to $out, the text report to $err
out=$(mktemp); err=$(mktemp); trap 'rm -f "$pin_cache" "$broken" "$broken.last" "$out" "$err"' EXIT
fx() { env PATH="$PWD/tests/fake-gh:$PATH" GH_TOKEN=x OWNER=o TOOLING="$stub" FAKE_GH=files FAKE_PATH=README.md "$@" scripts/sync.sh audit --json r >"$out" 2>"$err"; }
nogrep() { ! grep "$@"; }
jqt() { jq -e "$1" "$out" >/dev/null; } # a JSON assertion on the last audit
rc=0; fx || rc=$?; t test "$rc" = 1
t jqt '.[0].checks.squash_only | .status == "unknown" and .pass == false and .detail == "allow_merge_commit: cannot read; allow_rebase_merge: cannot read; squash_merge_commit_title: cannot read; squash_merge_commit_message: cannot read"'
t jqt '.[0].checks.ci_check_job | .status == "fail" and .pass == false'
t jqt '.[0].checks.repo_type | .status == "pass" and .pass == true and (has("detail") | not)'
rc=0; fx FAKE_GQL='{"squashMergeAllowed":false}' || rc=$?
t jqt '.[0].checks.squash_only.status == "fail"'                       # allow_squash_merge differs: drift wins
t grep -q '^        squash_only: allow_squash_merge: false (want true)' "$err"
rc=0; fx FAKE_PROBE=403 || rc=$?; t test "$rc" = 1
t jqt '.[0].checks.dependabot_alerts | .status == "unknown" and .pass == false and .detail == "cannot read: gh: Resource not accessible by personal access token (HTTP 403)"'
t jqt '.[0].checks.dependabot_security_updates.status == "unknown"'
t grep -q '^        unknown dependabot_alerts: cannot read: gh: Resource not accessible by personal access token (HTTP 403)' "$err"
t nogrep -q '^        dependabot_alerts' "$err"                          # not listed as drift
unk403=$(jq '.[0].unknown' "$out")
rc=0; fx FAKE_PROBE=ok || rc=$?
t jqt '.[0].checks.dependabot_alerts.status == "pass" and .[0].checks.dependabot_security_updates.status == "pass"'
t test "$unk403" = "$(($(jq '.[0].unknown' "$out") + 2))"              # the two probes were the difference
# a 404 is disabled: drift
rc=0; fx || rc=$?
t jqt '.[0].checks.dependabot_alerts | .status == "fail" and .detail == "Dependabot alerts disabled"'
# scores leave unknown checks out of numerator and denominator
std_den() { jq -r '.[0].score.standard | split("/")[1]' "$out"; }
fx FAKE_PROBE=ok || true; den_ok=$(std_den); fx FAKE_PROBE=403 || true; den_403=$(std_den)
t test "$den_ok" = "$((den_403 + 2))"
# a public repo whose token cannot read security_and_analysis: unknown, not "n/a (want enabled)" drift
rc=0; fx FAKE_PRIV=false || rc=$?
t jqt '.[0].checks.secret_scanning | .status == "unknown" and .detail == "security_and_analysis: cannot read"'
t jqt '.[0].checks.vuln_reporting.status == "fail"'

# tooling inventory glue (stub): cells land under `tooling`; only fail+differs|absent is drift, warn is printed; a crash
# or garbage is a broken run; wanted files are fetched by blob sha; a 403 lists the path, it is not broken
rc=0; fx FAKE_EXTRA=a/b.tool,c.forbidden || rc=$?; t test "$rc" = 1
t jqt '.[0].tooling.tool_a | .status == "differs" and .severity == "info" and .expected == "2"'
t jqt '.[0].tooling.files.value == "a/b.tool"'
t jqt '.[0].tooling.unreadable.value == "c.forbidden"'
t nogrep -q 'tooling tool_a' "$err"                                    # info prints nothing in the text report
rc=0; fx STUB_MODE=warn || rc=$?; t test "$rc" = 1
t grep -q '^        warn tooling tool_a: 1 (want 2)' "$err"
t nogrep -q '^        tooling tool_a' "$err"
rc=0; fx STUB_MODE=fail || rc=$?; t test "$rc" = 1
t grep -q '^        tooling tool_a: 1 (want 2)' "$err"
t nogrep -q 'warn tooling' "$err"
rc=0; fx STUB_MODE=crash || rc=$?; t test "$rc" = 2
t grep -q 'tooling.py collect failed' "$err"
rc=0; fx STUB_MODE=garbage || rc=$?; t test "$rc" = 2
# a missing lock file is a crash too
nolock=$(mktemp -d); cp "$stub" "$nolock/tooling.py"
rc=0; fx TOOLING="$nolock/tooling.py" || rc=$?; t test "$rc" = 2
rm -rf "$nolock"
# a wanted path with `..` or a leading `/` is a broken run
for p in ../x.tool /x.tool a/../x.tool .audit/paths.tool; do
  rc=0; fx FAKE_EXTRA="$p" || rc=$?; t test "$rc" = 2
  t grep -q 'refusing path' "$err"
done

# the repo list at its limit may be cut: a broken run
rc=0; PATH="$PWD/tests/fake-gh:$PATH" GH_TOKEN=x OWNER=o FAKE_LIST_N=1000 scripts/sync.sh audit >/dev/null 2>"$err" || rc=$?
t test "$rc" = 2; t grep -q 'repo list reached its limit' "$err"

# the standard stale workflow: missing and drifted copies fail the `stale` check, the byte-equal copy passes
stale() { PATH="$PWD/tests/fake-gh:$PATH" GH_TOKEN=x FAKE_GH=stale FAKE_PATH=.github/workflows/stale.yml FAKE_STALE_FILE=${1:-} OWNER=o scripts/sync.sh audit --json r 2>/dev/null || true; }
stale_is() { jq -e --argjson want "$1" '.[0].checks.stale | .pass == $want' <<<"$2" >/dev/null; }
t stale_is false "$(stale)"
t stale_is true "$(stale standard/workflows/stale.yml)"
drift=$(mktemp); sed 's/days-before-pr-stale: 30/days-before-pr-stale: 60/' standard/workflows/stale.yml > "$drift"
t stale_is false "$(stale "$drift")"
rm -f "$drift"

[ "$fail" = 0 ] && echo "sync.sh helpers and exit codes: ok"
exit "$fail"
