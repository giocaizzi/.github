#!/usr/bin/env bash
# Audit or apply ../standard. Usage: sync.sh audit [repo ...] | sync.sh apply <settings|labels|ruleset> [repo ...]
# `audit` is read-only. Default scope: every non-fork, non-archived repo of the owner.
# `ruleset` requires a green `check` job first (see docs/runbook-rollout.md): it blocks merges otherwise.
set -euo pipefail
OWNER=${OWNER:-giocaizzi}
DIR=$(cd "$(dirname "$0")/.." && pwd)

mode=${1:-}
case $mode in audit) ;; apply) what=${2:?settings|labels|ruleset}; shift ;; *) echo "usage: $0 audit|apply ..." >&2; exit 2 ;; esac
shift
repos=("$@")
[ ${#repos[@]} -gt 0 ] || while IFS= read -r r; do repos+=("$r"); done < <(
  gh repo list "$OWNER" --no-archived --source --limit 200 --json name -q '.[].name' | grep -vx '.github')

want_labels=$(grep -oE 'name: ("[^"]+"|[^,}]+)' "$DIR/standard/labels.yaml" | sed -E 's/name: //; s/"//g')

if [ "$mode" = apply ]; then
  for r in "${repos[@]}"; do
    case $what in
      settings)
        jq --argjson priv "$(gh api "repos/$OWNER/$r" -q .private)" 'del(.security_and_analysis) | if $priv then del(.allow_auto_merge) else . end' "$DIR/standard/repo-settings.json" | gh api -X PATCH "repos/$OWNER/$r" --input - >/dev/null
        # free plan: private repos get no secret scanning, auto-merge or rulesets; CI runs gitleaks instead
        if [ "$(gh api "repos/$OWNER/$r" -q .private)" = false ]; then
          jq '{security_and_analysis}' "$DIR/standard/repo-settings.json" | gh api -X PATCH "repos/$OWNER/$r" --input - >/dev/null
        fi ;;
      labels)
        yq_names=$(grep -E '^- \{' "$DIR/standard/labels.yaml")
        while IFS= read -r l; do
          n=$(sed -E 's/^- \{name: "?([^",]+)"?,.*/\1/' <<<"$l"); c=$(sed -E 's/.*color: "?([0-9a-fA-F]+)"?,.*/\1/' <<<"$l"); d=$(sed -E 's/.*description: "([^"]*)"\}.*/\1/' <<<"$l")
          gh label create "$n" --color "$c" --description "$d" --force -R "$OWNER/$r" >/dev/null
        done <<<"$yq_names" ;;
      ruleset)
        [ "$(gh api "repos/$OWNER/$r" -q .private)" = true ] && { echo "skip ruleset $r (private, free plan)"; continue; }
        id=$(gh api "repos/$OWNER/$r/rulesets" -q '.[]|select(.name=="main")|.id')
        if [ -n "$id" ]; then gh api -X PUT "repos/$OWNER/$r/rulesets/$id" --input "$DIR/standard/ruleset-main.json" >/dev/null
        else gh api "repos/$OWNER/$r/rulesets" --method POST --input "$DIR/standard/ruleset-main.json" >/dev/null; fi ;;
      *) echo "unknown: $what" >&2; exit 2 ;;
    esac
    echo "applied $what $r"
  done
  exit 0
fi

drift=0
for r in "${repos[@]}"; do
  out=()
  s=$(gh api "repos/$OWNER/$r")
  while IFS= read -r k; do
    want=$(jq -r --arg k "$k" '.[$k]' "$DIR/standard/repo-settings.json")
    got=$(jq -r --arg k "$k" '.[$k]' <<<"$s")
    [ "$k" = allow_auto_merge ] && [ "$(jq -r .private <<<"$s")" = true ] && continue
    [ "$want" = "$got" ] || out+=("$k: $got (want $want)")
  done < <(jq -r 'del(.security_and_analysis)|keys[]' "$DIR/standard/repo-settings.json")
  for k in secret_scanning secret_scanning_push_protection; do
    [ "$(jq -r .private <<<"$s")" = true ] && continue # needs GHAS; CI runs gitleaks
    got=$(jq -r --arg k "$k" '.security_and_analysis[$k].status // "n/a"' <<<"$s")
    [ "$got" = enabled ] || out+=("$k: $got (want enabled)")
  done
  if [ "$(jq -r .private <<<"$s")" = false ]; then
    gh api "repos/$OWNER/$r/rulesets" -q '.[].name' | grep -qx main || out+=("ruleset main: missing")
  fi
  have=$(gh label list -R "$OWNER/$r" --limit 200 --json name -q '.[].name')
  while IFS= read -r l; do grep -qxF "$l" <<<"$have" || out+=("label missing: $l"); done <<<"$want_labels"
  if [ ${#out[@]} -eq 0 ]; then echo "ok    $r"; else drift=1; echo "DRIFT $r"; printf '        %s\n' "${out[@]}"; fi
done
exit $drift
