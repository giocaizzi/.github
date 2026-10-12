#!/usr/bin/env bash
# Audit repos against ../standard. Read-only. Usage: sync.sh audit [repo ...]
# Default scope: every non-fork, non-archived repo of the owner.
set -euo pipefail
OWNER=${OWNER:-giocaizzi}
DIR=$(cd "$(dirname "$0")/.." && pwd)

[ "${1:-}" = audit ] || { echo "usage: $0 audit [repo ...]" >&2; exit 2; }
shift
repos=("$@")
[ ${#repos[@]} -gt 0 ] || while IFS= read -r r; do repos+=("$r"); done < <(
  gh repo list "$OWNER" --no-archived --source --limit 200 --json name -q '.[].name' | grep -vx '.github')

want_labels=$(grep -oE 'name: ("[^"]+"|[^,}]+)' "$DIR/standard/labels.yaml" | sed -E 's/name: //; s/"//g')

drift=0
for r in "${repos[@]}"; do
  out=()
  s=$(gh api "repos/$OWNER/$r")
  while IFS= read -r k; do
    want=$(jq -r --arg k "$k" '.[$k]' "$DIR/standard/repo-settings.json")
    got=$(jq -r --arg k "$k" '.[$k]' <<<"$s")
    [ "$want" = "$got" ] || out+=("$k: $got (want $want)")
  done < <(jq -r 'del(.security_and_analysis)|keys[]' "$DIR/standard/repo-settings.json")
  for k in secret_scanning secret_scanning_push_protection; do
    got=$(jq -r --arg k "$k" '.security_and_analysis[$k].status // "n/a"' <<<"$s")
    [ "$got" = enabled ] || out+=("$k: $got (want enabled)")
  done
  gh api "repos/$OWNER/$r/rulesets" -q '.[].name' | grep -qx main || out+=("ruleset main: missing")
  have=$(gh label list -R "$OWNER/$r" --limit 200 --json name -q '.[].name')
  while IFS= read -r l; do grep -qxF "$l" <<<"$have" || out+=("label missing: $l"); done <<<"$want_labels"
  if [ ${#out[@]} -eq 0 ]; then echo "ok    $r"; else drift=1; echo "DRIFT $r"; printf '        %s\n' "${out[@]}"; fi
done
exit $drift
