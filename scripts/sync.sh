#!/usr/bin/env bash
# Audit or apply ../standard. Usage: sync.sh audit [--json] [--visibility public|private|all] [repo ...] | sync.sh apply <settings|labels|workflows|gitignore|ruleset> [repo ...] | sync.sh onboard <repo> <type> [flag,...]
# `audit` is read-only; exit 0 ok, 1 drift, 2 empty scope. `--json` prints a JSON array on stdout and the text report on stderr.
# Default scope: every non-fork, non-archived repo of the owner, filtered by --visibility (default all).
# Repo type and flags come from the repo's GitHub topics (std-<type>, std-<flag>; parser: scripts/meta.jq).
# `ruleset` requires a green `check` job first (see docs/runbook-rollout.md): it blocks merges otherwise.
set -euo pipefail
OWNER=${OWNER:-giocaizzi}
DIR=$(cd "$(dirname "$0")/.." && pwd)

mode=${1:-}
if [ "$mode" = onboard ]; then
  r=${2:?usage: sync.sh onboard <repo> <type> [flag,...]} t=${3:?usage: sync.sh onboard <repo> <type> [flag,...]}
  # add std-<type> and std-<flag> topics, keeping existing ones
  gh api "repos/$OWNER/$r/topics" -q .names | jq --arg t "$t" --arg f "${4:-}" \
    '{names: (. + ([$t] + ($f | split(",")) | map(select(length > 0) | "std-" + .)) | unique)}' \
    | gh api -X PUT "repos/$OWNER/$r/topics" --input - >/dev/null
  for w in settings labels workflows gitignore; do "$0" apply "$w" "$r"; done
  base=$(gh api "repos/$OWNER/$r" -q .default_branch)
  sha=$(gh api "repos/$OWNER/$r/commits/$base" -q .sha)
  ok=$(gh api "repos/$OWNER/$r/commits/$sha/check-runs?check_name=check" -q '[.check_runs[]|select(.conclusion=="success")]|length')
  if [ "${ok:-0}" -gt 0 ]; then "$0" apply ruleset "$r"
  else echo "ruleset not applied: no green \`check\` on $base yet; merge the CI + workflows PRs, then run: sync.sh apply ruleset $r"; fi
  exec "$0" audit "$r"
fi
case $mode in audit) ;; apply) what=${2:?settings|labels|workflows|gitignore|ruleset}; shift ;; *) echo "usage: $0 audit|apply|onboard ..." >&2; exit 2 ;; esac
shift
json=0 vis=all
while [ "$mode" = audit ] && [ $# -gt 0 ]; do
  case $1 in --json) json=1; shift ;; --visibility) vis=${2:-}; shift 2 ;; *) break ;; esac
done
case $vis in public|private|all) ;; *) echo "--visibility: public|private|all" >&2; exit 2 ;; esac
repos=("$@")
[ ${#repos[@]} -gt 0 ] || while IFS= read -r r; do repos+=("$r"); done < <(
  gh repo list "$OWNER" --no-archived --source --limit 200 --json name,visibility \
    | jq -r --arg v "$vis" '.[] | select($v == "all" or (.visibility | ascii_downcase) == $v) | .name' | grep -vx '.github')
# Fail loudly instead of passing on an empty scope (e.g. a missing or under-scoped token).
[ ${#repos[@]} -gt 0 ] || { echo "no repos to check: is GH_TOKEN set and allowed to list repos?" >&2; exit 2; }


want_labels=$(grep -oE 'name: ("[^"]+"|[^,}]+)' "$DIR/standard/labels.yaml" | sed -E 's/name: //; s/"//g')

if [ "$mode" = apply ]; then
  for r in "${repos[@]}"; do
    case $what in
      settings)
        jq --argjson priv "$(gh api "repos/$OWNER/$r" -q .private)" 'del(.security_and_analysis, .private_vulnerability_reporting) | if $priv then del(.allow_auto_merge) else . end' "$DIR/standard/repo-settings.json" | gh api -X PATCH "repos/$OWNER/$r" --input - >/dev/null
        # free plan: private repos get no secret scanning, auto-merge or rulesets; CI runs gitleaks instead
        if [ "$(gh api "repos/$OWNER/$r" -q .private)" = false ]; then
          jq '{security_and_analysis}' "$DIR/standard/repo-settings.json" | gh api -X PATCH "repos/$OWNER/$r" --input - >/dev/null
          gh api -X PUT "repos/$OWNER/$r/private-vulnerability-reporting" >/dev/null
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
      gitignore)
        # Opens a PR appending the missing standard/gitignore-agents lines to .gitignore on `chore/standard-gitignore`.
        base=$(gh api "repos/$OWNER/$r" -q .default_branch)
        body=$(gh api "repos/$OWNER/$r/contents/.gitignore?ref=$base" -H 'Accept: application/vnd.github.raw' 2>/dev/null || true)
        missing=$(grep -vxF -f <(printf '%s\n' "$body") <(grep -v '^#' "$DIR/standard/gitignore-agents") || true)
        [ -z "$missing" ] && { echo "gitignore $r: up to date"; continue; }
        sha=$(gh api "repos/$OWNER/$r/git/ref/heads/$base" -q .object.sha)
        branch=chore/standard-gitignore
        gh api "repos/$OWNER/$r/git/refs" -f ref="refs/heads/$branch" -f sha="$sha" >/dev/null 2>&1 || true
        new=$(printf '%s\n\n%s\n%s\n' "${body%$'\n'}" "$(head -1 "$DIR/standard/gitignore-agents")" "$missing" | sed '/./,$!d')
        fsha=$(gh api "repos/$OWNER/$r/contents/.gitignore?ref=$branch" -q .sha 2>/dev/null || true)
        gh api -X PUT "repos/$OWNER/$r/contents/.gitignore" -f branch="$branch" -f message="chore: ignore local agent state" \
          -f content="$(printf '%s\n' "$new" | base64 | tr -d '\n')" ${fsha:+-f sha="$fsha"} >/dev/null
        gh pr create -R "$OWNER/$r" -B "$base" -H "$branch" --title "chore: ignore local agent state" \
          --body "Adds the agent-config ignore lines from giocaizzi/.github (\`standard/gitignore-agents\`, docs/standard.md Agent config): personal overrides, Claude worktrees and agent install dirs stay out of git; shared agent config stays tracked." >/dev/null 2>&1 || true ;;
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

# --- audit (read-only) ---
# Checks: standard (always, drift), typed (by topic type/flags and repo contents, drift), extra (presence only, never drift).
[ $json = 1 ] && exec 3>&1 1>&2 # JSON on fd 3 (stdout), text report on stderr
std=$(cat "$DIR/standard/repo-settings.json")
link_sha=$(printf AGENTS.md | git hash-object --stdin) # blob of a symlink pointing to AGENTS.md
gh_paths=$(gh api "repos/$OWNER/.github/git/trees/main?recursive=1" -q '.tree[].path') # inherited community health files

# Helpers read the current repo's globals ($r, $paths, $entries, $m, ...).
# shellcheck disable=SC2317,SC2329 # job_ok etc. are invoked through ok()
{
  chk() { rec+="$1	$2	$3	${4:-}"$'\n'; }        # id kind pass|present detail
  ok() { if "$@"; then echo true; else echo false; fi; }
  has() { grep -qE "^($1)$" <<<"$paths"; }
  raw() { if has "${1//./\\.}"; then gh api "repos/$OWNER/$r/contents/$1?ref=$base" -H 'Accept: application/vnd.github.raw' || true; fi; }
  excepted() { jq -e --arg c "$1" '.exceptions | index($c)' <<<"$m" >/dev/null; }
  job_ok() { grep -qE '^    needs:' <<<"$job" && grep -qE '^    if: (\$\{\{ *)?always\(\)' <<<"$job"; }
  agent_ignore_missing() { grep -vxF -f <(raw .gitignore) <(grep -v '^#' "$DIR/standard/gitignore-agents") || true; }
  local_claude() { has 'AGENTS\.md' && raw .gitignore | grep -qx /CLAUDE.md; }
  no_poetry() { ! has '(.*/)?poetry\.lock' && ! grep -q '^\[tool\.poetry' <<<"$py"; }
  own_or_inherited() { has "$1" || grep -qE "^($1)$" <<<"$gh_paths"; }
  # workflow jobs with a publish/deploy step but no `environment:`; heuristic documented in docs/standard.md
  unenv_jobs() { awk '
    /^jobs:/ {j=1; next}
    j && /^[^ #]/ {j=0}
    j && /^  [A-Za-z0-9_-]+:/ {n=$1; sub(/:$/, "", n); next}
    j && n {b[n]=b[n] "\n" $0}
    END {for (n in b) if ((b[n] ~ /gh-action-pypi-publish|uv publish|docker push|deploy-pages|cosign sign|wrangler deploy|\/webhooks\/|(scp|rsync|ssh) / ||
      (b[n] ~ /build-push-action/ && b[n] ~ /push: *(true|\$\{\{)/)) && b[n] !~ /\n    environment:/) print n}'; }
  # a workflow that publishes to PyPI by trusted publishing in environment `pypi`, triggered by a release
  pypi_wf_ok() {
    grep -qE 'gh-action-pypi-publish|uv publish' <<<"$1" && grep -qE 'id-token: *write' <<<"$1" \
      && { grep -qE 'environment: *pypi' <<<"$1" || grep -A2 'environment:' <<<"$1" | grep -qE 'name: *pypi'; } \
      && grep -qE '^  release:|releases?_created' <<<"$1" && ! grep -qE 'PYPI_API_TOKEN|UV_PUBLISH_TOKEN|password:|--token' <<<"$1"
  }
  setting() { # id key...
    local id=$1 d="" k want got; shift
    for k; do
      want=$(jq -r --arg k "$k" '.[$k]' <<<"$std"); got=$(jq -r --arg k "$k" '.[$k]' <<<"$s")
      [ "$want" = "$got" ] || d+="$k: $got (want $want); "
    done
    chk "$id" standard "$(ok test -z "$d")" "${d%; }"
  }
}

drift=0
results=""
for r in "${repos[@]}"; do
  rec="" ex=""
  s=$(gh api "repos/$OWNER/$r")
  # REST returns the merge settings as null to a read-only fine-grained token; GraphQL returns them
  # shellcheck disable=SC2016 # $o, $n and $g are GraphQL and jq variables
  s=$(jq -c --argjson g "$(gh api graphql -f o="$OWNER" -f n="$r" -q .data.repository -f query='
    query($o: String!, $n: String!) { repository(owner: $o, name: $n) { squashMergeAllowed mergeCommitAllowed
      rebaseMergeAllowed deleteBranchOnMerge autoMergeAllowed squashMergeCommitTitle squashMergeCommitMessage } }')" '
    . + {allow_squash_merge: $g.squashMergeAllowed, allow_merge_commit: $g.mergeCommitAllowed,
      allow_rebase_merge: $g.rebaseMergeAllowed, delete_branch_on_merge: $g.deleteBranchOnMerge,
      allow_auto_merge: $g.autoMergeAllowed, squash_merge_commit_title: $g.squashMergeCommitTitle,
      squash_merge_commit_message: $g.squashMergeCommitMessage}' <<<"$s")
  priv=$(jq -r .private <<<"$s")
  base=$(jq -r .default_branch <<<"$s")
  entries=$(gh api "repos/$OWNER/$r/git/trees/$base?recursive=1" -q '.tree[]|select(.type=="blob")|"\(.mode) \(.sha) \(.path)"')
  paths=$(cut -d' ' -f3- <<<"$entries")
  m=$(jq -c -f "$DIR/scripts/meta.jq" <<<"$s")
  type=$(jq -r .type <<<"$m")
  released=$(jq -r .released <<<"$m")
  ci=$(raw .github/workflows/ci.yml); mk=$(raw Makefile); py=$(raw pyproject.toml)

  # standard
  chk repo_type standard "$(ok test "$type" != unknown)" "want exactly one std-<type> topic, got: $(jq -r '.types | join(",")' <<<"$m")"
  job=$(awk '/^  check:/{f=1;next} f&&/^  [^ #]/{f=0} f' <<<"$ci")
  if [ -z "$ci" ]; then chk ci_check_job standard false "no .github/workflows/ci.yml"
  elif [ -z "$job" ]; then chk ci_check_job standard false "ci.yml has no job check"
  else chk ci_check_job standard "$(ok job_ok)" "check job lacks needs + if: always()"; fi
  chk make_check standard "$(ok grep -qE '^check:' <<<"$mk")" "Makefile has no check target"
  chk gitleaks standard "$(ok grep -q gitleaks <<<"$ci")" "ci.yml does not run gitleaks"
  for w in pr-title label-guard; do
    got=$(awk -v p=".github/workflows/$w.yml" '$3==p{print $2}' <<<"$entries")
    chk "${w/-/_}" standard "$(ok test "$got" = "$(git hash-object "$DIR/standard/workflows/$w.yml")")" "workflow drift: $w.yml"
  done
  chk dependabot standard "$(ok has '\.github/dependabot\.ya?ml')" "no .github/dependabot.yml"
  # every updates entry needs a non-empty `groups:` block; prints "<entries> <ungrouped>"
  read -r n bad < <( { raw .github/dependabot.yml; raw .github/dependabot.yaml; } | awk '
    /^[[:space:]]*- package-ecosystem:/ {n++; g[n]=0; gi=-1; next}
    n && /^[[:space:]]*groups:[[:space:]]*(#.*)?$/ {match($0, /^ */); gi=RLENGTH; next}
    gi >= 0 && NF && $1 !~ /^#/ {match($0, /^ */); if (RLENGTH > gi) g[n]=1; gi=-1}
    END {for (i = 1; i <= n; i++) if (!g[i]) b++; print n+0, b+0}')
  chk dependabot_grouped standard "$(ok test "$n" -gt 0 -a "$bad" = 0)" "$bad of $n dependabot updates entries without groups"
  # every updates entry needs commit-message.prefix = Conventional Commit type(scope), so PR titles pass pr-title.yml
  read -r n bad < <( { raw .github/dependabot.yml; raw .github/dependabot.yaml; } | awk '
    /^[[:space:]]*- package-ecosystem:/ {n++; p[n]=0; ci=-1; next}
    n && /^[[:space:]]*commit-message:[[:space:]]*(#.*)?$/ {match($0, /^ */); ci=RLENGTH; next}
    ci >= 0 && NF && $1 !~ /^#/ {match($0, /^ */); if (RLENGTH <= ci) ci=-1
      else if ($1 == "prefix:") {v=$2; gsub(/["\047]/, "", v)
        if (v ~ /^(feat|fix|perf|refactor|revert|docs|style|test|build|ci|chore)(\([a-z0-9._\/-]+\))?$/) p[n]=1}}
    END {for (i = 1; i <= n; i++) if (!p[i]) b++; print n+0, b+0}')
  chk dependabot_prefix standard "$(ok test "$n" -gt 0 -a "$bad" = 0)" "$bad of $n dependabot updates entries without a Conventional Commit commit-message.prefix"
  chk agents_md standard "$(ok has AGENTS\\.md)" "no AGENTS.md"
  d=$(agent_ignore_missing | paste -sd, -)
  chk agent_ignore standard "$(ok test -z "$d")" "missing in .gitignore: $d (sync.sh apply gitignore)"
  if excepted claude_symlink; then # local untracked symlink, gitignored (docs/standard.md Exceptions)
    chk claude_symlink standard "$(ok local_claude)" "want AGENTS.md and /CLAUDE.md in .gitignore"
  else chk claude_symlink standard "$(ok grep -qx "120000 $link_sha CLAUDE.md" <<<"$entries")" "CLAUDE.md is not a symlink to AGENTS.md"; fi
  setting squash_only allow_squash_merge allow_merge_commit allow_rebase_merge squash_merge_commit_title squash_merge_commit_message
  setting delete_branch delete_branch_on_merge
  if [ "$priv" = true ]; then ex+="auto_merge ruleset_main secret_scanning vuln_reporting " # free plan: unavailable
  else
    setting auto_merge allow_auto_merge
    if grep -qx "$r" "$DIR/standard/ruleset-exceptions.txt"; then ex+="ruleset_main "
    else
      id=$(gh api "repos/$OWNER/$r/rulesets" -q '.[]|select(.name=="main")|.id')
      if [ -z "$id" ]; then chk ruleset_main standard false "ruleset main: missing"
      else
        want=$(jq -r '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context' "$DIR/standard/ruleset-main.json" | sort)
        got=$(gh api "repos/$OWNER/$r/rulesets/$id" -q '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context' | sort)
        chk ruleset_main standard "$(ok test "$want" = "$got")" "ruleset main: required checks $(paste -sd, - <<<"$got") (want $(paste -sd, - <<<"$want"))"
      fi
    fi
    d=$(jq -r '.security_and_analysis // {} | [("secret_scanning","secret_scanning_push_protection") as $k | select(.[$k].status != "enabled") | "\($k): \(.[$k].status // "n/a") (want enabled)"] | join("; ")' <<<"$s")
    chk secret_scanning standard "$(ok test -z "$d")" "$d"
    chk vuln_reporting standard "$(gh api "repos/$OWNER/$r/private-vulnerability-reporting" -q .enabled 2>/dev/null || echo false)" "private vulnerability reporting disabled"
  fi
  have=$(gh label list -R "$OWNER/$r" --limit 200 --json name -q '.[].name')
  d=$( { grep -vxF -f <(printf '%s\n' "$have") <<<"$want_labels" | sed 's/^/label missing: /' || true
         grep -vxF -f <(printf '%s\n' "$want_labels") <<<"$have" | sed 's/^/label extra: /' || true; } | paste -sd';' - | sed 's/;/; /g')
  chk labels standard "$(ok test -z "$d")" "$d"
  chk no_poetry standard "$(ok no_poetry)" "poetry in use (poetry.lock or [tool.poetry])"
  chk security_md standard "$(ok own_or_inherited '(\.github/|docs/)?SECURITY\.md')" "no SECURITY.md (own or inherited)"
  chk issue_templates standard "$(ok own_or_inherited '\.github/ISSUE_TEMPLATE/.+')" "no issue templates (own or inherited)"
  lic=$(ok has 'LICEN[CS]E(\.md|\.txt)?')
  if [ "$priv" = false ]; then chk license standard "$lic" "no LICENSE"; else chk license extra "$lic"; fi

  # typed
  tests=$(ok has '(.*/)?(tests?|__tests__)/.*|(.*/)?test_[^/]*\.py|.*_test\.py|.*\.(test|spec)\.[cm]?[jt]sx?')
  case $type in python|typescript) chk tests typed "$tests" "no tests found" ;; *) chk tests extra "$tests" ;; esac
  if [ "$type" = python ]; then
    d=""
    has uv\\.lock || d+="uv.lock "
    for t in ruff mypy pytest; do grep -q "$t" <<<"$py" || has "\.?$t\.(toml|ini)" || d+="$t "; done
    chk python_toolchain typed "$(ok test -z "$d")" "missing: ${d% }"
  fi
  if has '(.*/)?Dockerfile[^/]*'; then
    chk hadolint typed "$(ok grep -q hadolint <<<"$ci$mk")" "Dockerfile without hadolint in ci.yml or Makefile"
    chk docker extra true
  else chk docker extra false; fi
  iac=$(ok has '.*\.tf')
  if [ "$type" = infra ]; then chk iac_validate typed "$(ok grep -q validate <<<"$ci$mk")" "no validate step in ci.yml or Makefile"
  else chk iac extra "$iac"; fi
  [ "$released" = true ] && chk release_please typed "$(ok has release-please-config\\.json)" "released but no release-please-config.json"
  [ "$released" = true ] && has uv\\.lock && has release-please-config\\.json &&
    chk uv_lock_release typed "$(ok grep -q 'uv\.lock' <<<"$(raw release-please-config.json)")" "uv.lock not in release-please extra-files (its recorded version goes stale after each release)"
  for f in codecov.yml .codecov.yml; do
    has "${f//./\\.}" && chk codecov_informational typed "$(ok grep -q 'informational: true' <<<"$(raw "$f")")" "$f lacks informational: true"
  done

  # environments / PyPI: environments exist on public repos (private ones need a paid plan)
  pypi=$(jq -r .pypi <<<"$m"); deploys=$(jq -r .deploys <<<"$m")
  if [ "$pypi" = true ] || [ "$deploys" = true ]; then
    if [ "$priv" = true ]; then ex+="environments pypi_publish "
    else
      d="" pypi_ok=false
      while IFS= read -r f; do
        c=$(raw "$f")
        while IFS= read -r j; do [ -n "$j" ] && d+="$f job $j has no environment; "; done < <(unenv_jobs <<<"$c")
        pypi_wf_ok "$c" && pypi_ok=true
      done < <(grep -E '^\.github/workflows/[^/]+\.ya?ml$' <<<"$paths")
      while IFS= read -r sec; do d+="repository secret $sec (use an environment secret); "; done \
        < <(gh api "repos/$OWNER/$r/actions/secrets" -q '.secrets[].name' | grep -E 'PYPI|DEPLOY|PORTAINER|WEBHOOK|SSH|REGISTRY|DOCKER' || true)
      chk environments typed "$(ok test -z "$d")" "${d%; }"
      if [ "$pypi" = true ]; then
        has release-please-config\\.json || pypi_ok=false
        chk pypi_publish typed "$pypi_ok" "needs release-please and a release-triggered workflow publishing by trusted publishing (id-token: write, no token) in environment pypi"
      fi
    fi
  fi

  # extra
  chk pre_commit extra "$(ok has '\.pre-commit-config\.ya?ml')"
  chk codeowners extra "$(ok has '(\.github/|docs/)?CODEOWNERS')"
  chk changelog extra "$(ok has '(.*/)?CHANGELOG\.md')"
  chk docs_site extra "$(jq -r '.has_pages or ((.homepage // "") != "")' <<<"$s")"

  fails=$(awk -F'\t' '$2!="extra" && $3=="false" {print $1": "$4}' <<<"$rec")
  if [ -z "$fails" ]; then echo "ok    $r"; else drift=1; echo "DRIFT $r"; while IFS= read -r l; do printf '        %s\n' "$l"; done <<<"$fails"; fi
  results+=$(jq -n --arg repo "$r" --arg type "$type" --argjson released "$released" --argjson private "$priv" --arg ex "$ex" --arg rec "$rec" '
    [$rec | split("\n")[] | select(length > 0) | split("\t") | {id: .[0], kind: .[1], pass: (.[2] == "true"), detail: .[3]}] as $all
    | ($all | map(select(.kind != "extra"))) as $c | ($all | map(select(.kind == "extra"))) as $e
    | def score(k): ($c | map(select(.kind == k))) | "\(map(select(.pass)) | length)/\(length)";
    {repo: $repo, type: $type, released: $released, private: $private, exempt: ($ex | split(" ") | map(select(length > 0))),
     checks: ($c | map({(.id): ({kind, pass} + if .pass or .detail == "" then {} else {detail} end)}) | add // {}),
     extras: ($e | map({(.id): {kind, present: .pass}}) | add // {}),
     score: {standard: score("standard"), typed: score("typed"), extras: "\($e | map(select(.pass)) | length)/\($e | length)"}}')$'\n'
done
[ $json = 1 ] && jq -s . <<<"$results" >&3
exit $drift
