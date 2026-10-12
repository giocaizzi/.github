#!/usr/bin/env bash
# Audit or apply ../standard. Usage: sync.sh audit [repo ...] | sync.sh apply <settings|labels|workflows|ruleset> [repo ...]
# `audit` is read-only. Default scope: every non-fork, non-archived repo of the owner.
# `ruleset` requires a green `check` job first (see docs/runbook-rollout.md): it blocks merges otherwise.
set -euo pipefail
OWNER=${OWNER:-giocaizzi}
DIR=$(cd "$(dirname "$0")/.." && pwd)

mode=${1:-}
case $mode in audit) ;; apply) what=${2:?settings|labels|workflows|ruleset}; shift ;; *) echo "usage: $0 audit|apply ..." >&2; exit 2 ;; esac
shift
repos=("$@")
[ ${#repos[@]} -gt 0 ] || while IFS= read -r r; do repos+=("$r"); done < <(
  gh repo list "$OWNER" --no-archived --source --limit 200 --json name -q '.[].name' | grep -vx '.github')
# Fail loudly instead of passing on an empty scope (e.g. a missing or under-scoped token).
[ ${#repos[@]} -gt 0 ] || { echo "no repos to check: is GH_TOKEN set and allowed to list repos?" >&2; exit 2; }


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
        done <<<"$yq_names"
        # prune: delete every label not in the standard (removes it from issues/PRs too)
        gh label list -R "$OWNER/$r" --limit 500 --json name -q '.[].name' | while IFS= read -r l; do
          grep -qxF "$l" <<<"$want_labels" || gh label delete "$l" --yes -R "$OWNER/$r" >/dev/null
        done ;;
      workflows)
        # Opens a PR adding/updating standard/workflows/* on a `chore/standard-workflows` branch. Merge it, then apply the ruleset.
        base=$(gh api "repos/$OWNER/$r" -q .default_branch)
        sha=$(gh api "repos/$OWNER/$r/git/ref/heads/$base" -q .object.sha)
        branch=chore/standard-workflows
        gh api "repos/$OWNER/$r/git/refs" -f ref="refs/heads/$branch" -f sha="$sha" >/dev/null 2>&1 || true
        changed=0
        for f in "$DIR"/standard/workflows/*.yml; do
          path=.github/workflows/$(basename "$f")
          cur=$(gh api "repos/$OWNER/$r/contents/$path?ref=$branch" -q .sha 2>/dev/null || true)
          [ "$cur" = "$(git hash-object "$f")" ] && continue
          gh api -X PUT "repos/$OWNER/$r/contents/$path" -f branch="$branch" -f message="ci: add standard $(basename "$f")" \
            -f content="$(base64 < "$f" | tr -d '\n')" ${cur:+-f sha="$cur"} >/dev/null
          changed=1
        done
        if [ $changed = 1 ]; then
          gh pr create -R "$OWNER/$r" -B "$base" -H "$branch" --title "ci: add standard workflows" \
          --body "Adds the standard workflows from giocaizzi/.github (\`standard/workflows/\`), e.g. the required \`Validate PR title\` check." >/dev/null 2>&1 || true
        fi ;;
      ruleset)
        [ "$(gh api "repos/$OWNER/$r" -q .private)" = true ] && { echo "skip ruleset $r (private, free plan)"; continue; }
        grep -qx "$r" "$DIR/standard/ruleset-exceptions.txt" && { echo "skip ruleset $r (exception)"; continue; }
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
  if [ "$(jq -r .private <<<"$s")" = false ] && ! grep -qx "$r" "$DIR/standard/ruleset-exceptions.txt"; then
    id=$(gh api "repos/$OWNER/$r/rulesets" -q '.[]|select(.name=="main")|.id')
    if [ -z "$id" ]; then out+=("ruleset main: missing")
    else
      want=$(jq -r '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context' "$DIR/standard/ruleset-main.json" | sort)
      got=$(gh api "repos/$OWNER/$r/rulesets/$id" -q '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context' | sort)
      [ "$want" = "$got" ] || out+=("ruleset main: required checks $(echo "$got" | paste -sd, -) (want $(echo "$want" | paste -sd, -))")
    fi
  fi
  for f in "$DIR"/standard/workflows/*.yml; do
    got=$(gh api "repos/$OWNER/$r/contents/.github/workflows/$(basename "$f")" -q .sha 2>/dev/null || true)
    [ "$got" = "$(git hash-object "$f")" ] || out+=("workflow drift: $(basename "$f")")
  done
  have=$(gh label list -R "$OWNER/$r" --limit 200 --json name -q '.[].name')
  while IFS= read -r l; do grep -qxF "$l" <<<"$have" || out+=("label missing: $l"); done <<<"$want_labels"
  while IFS= read -r l; do grep -qxF "$l" <<<"$want_labels" || out+=("label extra: $l"); done <<<"$have"
  if [ ${#out[@]} -eq 0 ]; then echo "ok    $r"; else drift=1; echo "DRIFT $r"; printf '        %s\n' "${out[@]}"; fi
done
exit $drift
