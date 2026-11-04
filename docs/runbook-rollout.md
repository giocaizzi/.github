# Runbook: audit and roll out the standard

Prereqs: `gh` authenticated with `repo` + `administration` scope, `jq`, `shellcheck`, `uv` (the workflow checker `scripts/workflow.py` runs on it, with its pinned parser).

## Audit (read-only)
```bash
make audit                      # all in-scope repos (VISIBILITY=public|private to narrow)
scripts/sync.sh audit greenhouse # one repo
```
Exit code 0 ok, 1 when any repo drifts (a failing standard or typed check), 2 when no repo is in scope or the audit itself broke (a GitHub API error other than a 404 tag lookup, a failed fetch, a truncated repo tree, a tree path with a control character, a missing checker lock, a crash of `scripts/workflow.py` or `uv`, or any other failed command; the settings probes that answer 404 for "disabled" read a failure as disabled, which is drift; the cause is printed). The weekly workflow fails on 2 and files no drift issue. Output lists each failing check as `id: detail`.

JSON for the dashboard:
```bash
make audit JSON=1 > audit.json         # JSON on stdout, text report on stderr
scripts/sync.sh audit --json greenhouse # one repo
```
One object per repo: `repo`, `type`, `released`, `private`, `exempt` (check ids that do not apply), `checks` (`{id: {kind, pass, detail?}}`), `extras` (`{id: {kind, present}}`), `score` (`standard`, `typed`, `extras` as `n/m`).

## New repo
1. Create it from the template: `gh repo create giocaizzi/<name> --template giocaizzi/template --public --clone` (starts with CI `check`, PR-title, label-guard and todo-issues workflows, Dependabot, Makefile, AGENTS.md, LICENSE).
2. `make onboard REPO=<name> TYPE=<python|typescript|go|infra|config|docs> [FLAGS=released,pypi,deploys]` here: adds the `std-<type>` and `std-<flag>` topics (existing topics kept), applies settings, labels, workflows and the agent ignore lines, applies the ruleset once `check` is green on the default branch, then audits the repo. The audit fails a repo without exactly one `std-<type>` topic.
3. If it printed "ruleset not applied", merge any open PRs, wait for `check` on the default branch, then `scripts/sync.sh apply ruleset <name>` and `scripts/sync.sh apply todos <name>`.

## PyPI trusted publisher (one-time, manual, per project)
On pypi.org, project > Publishing > add a GitHub trusted publisher: owner `giocaizzi`, repository, workflow file name (e.g. `python-publish.yml`), environment `pypi`. For a project not yet on PyPI, add a pending publisher under the account's Publishing page. Then create the `pypi` environment in the repo (Settings > Environments), delete any `PYPI_API_TOKEN` repository secret, and make the workflow `id-token: write` + `environment: pypi` with no token. Deploy secrets move to the deploy job's environment the same way. `scripts/sync.sh audit <repo>` must report `environments` and `pypi_publish` as passing.

## Apply, in this order (low risk first)
1. **Settings**: `scripts/sync.sh apply settings <repo>` (repo settings and Dependabot alerts + security updates on every repo; secret scanning and private vulnerability reporting on public repos).
2. **Labels**: `scripts/sync.sh apply labels <repo>` creates `standard/labels.yaml` plus the repo's `.github/labels.yaml` extras and deletes every other label (and strips it from issues). To keep a repo-only label, merge it into that repo's `.github/labels.yaml` first. Run it on every repo after `standard/labels.yaml` drops a label.
3. **Workflows**: `scripts/sync.sh apply workflows <repo>` opens a PR with `standard/workflows/*` (PR title check); merge it. After a change to `standard/workflows/`, open the same change in `giocaizzi/template` too (its copies are byte-equal). A copy that differs only in its `uses:` refs, each a SHA its version tag resolves to upstream (a Dependabot bump), is left alone; any other copy is replaced, keeping the repo's verified pins newer than the standard's. The repo's own workflows (`ci.yml` and any other) meet the [CI hygiene](standard.md#ci-hygiene) rules by hand, via PR: `scripts/sync.sh audit <repo>` names each file (workflows and `action.yml`) and job that fails `wf_parsed`, `wf_permissions`, `wf_timeout`, `wf_concurrency` or `wf_pinned`.
   Once the PR with `todo-issues.yml` is merged, `scripts/sync.sh apply todos <repo>` imports the repo's existing TODOs as `todo` issues (safe to rerun: titles are deduplicated).
4. **Agent ignore**: `scripts/sync.sh apply gitignore <repo>` opens a PR appending the missing `standard/gitignore-agents` lines to `.gitignore`; merge it.
5. **CI**: land a `check` job (and `make check`) in the repo first, via PR.
6. **Ruleset**: only after `check` and `Validate PR title` have run green once: `gh api repos/giocaizzi/<repo>/rulesets --method POST --input standard/ruleset-main.json`. Applying earlier blocks every merge.
7. Re-run the audit; it must report `ok` for the repo.

## Tier a repo's CI (repos with a merge queue only)
Prereq: the default branch requires a merge queue with an empty bypass list (`gh api repos/<owner>/<repo>/rules/branches/main --jq '.[] | select(.type == "merge_queue")'` prints the rule, with the `ruleset_id` whose `gh api repos/<owner>/<repo>/rulesets/<id> --jq .bypass_actors` prints `[]`). Without one, stop: the PR run stays the full gate ([CI tiers](standard.md#ci-tiers)).
1. In one PR to the repo: add `merge_group:` and `workflow_dispatch:` to `ci.yml`'s `on`, give each full-tier job `if: github.event_name == 'merge_group' || github.event_name == 'workflow_dispatch' || (github.event_name == 'pull_request' && !github.event.pull_request.draft && vars.CI_FULL_TIER_ON_PR == 'true')` (the last clause is the rollback below), list exactly those jobs in `check`'s `FULL_TIER` allowlist, and point `make prepush` at the light tier plus the touched packages' integration tests.
2. Verify on that PR: `check` and `Validate PR title` are green, and the full-tier jobs show `skipped` (`gh pr checks <n>`).
3. Verify in the queue: after the PR enters the queue, the `merge_group` run ran every full-tier job (`gh run list --workflow ci.yml --event merge_group --limit 1`, then `gh run view <id>`), and `check` passed there.
4. Measure: compare minutes per workflow and event before and after (harness [ci-cost.md](https://github.com/giocaizzi/harness/blob/main/plugins/dev-tools/skills/repo-standard/references/ci-cost.md)).

Rollback: revert that PR; the required checks never changed, so the ruleset needs nothing.

Run the full tier on PRs again without a revert (for example while a full-tier failure keeps slipping past the PR run); a repo tiered before the rollback existed first adds its clause to each full-tier `if`: `gh variable set CI_FULL_TIER_ON_PR --repo <owner>/<repo> --body true`. The next ready PR run shows the full-tier jobs as run, not `skipped` (`gh pr checks <n>`). Back to tiers: `gh variable delete CI_FULL_TIER_ON_PR --repo <owner>/<repo>`.

## Skip CI on drafts and add the local gate (every repo)
1. In one PR to the repo: add `make prepush` (`prepush: check` without tiers), give `ci.yml` the draft triggers and conditions of [Drafts](standard.md#ci-hygiene) (as `giocaizzi/template`'s `ci.yml` does once its matching change lands), and keep every job id unchanged.
2. Verify as a draft: a push runs no `ci.yml` job, and `gh pr checks <n>` lists no `check` (the skipped job shows under its unevaluated name expression). `Validate PR title` still runs, as before.
3. Verify on ready: `gh pr ready <n>` starts a run in which `check` and `Validate PR title` report and pass.

Rollback: revert that PR; the required checks never changed.

## Dependabot bumps in this repo
Dependabot bumps the actions in `.github/workflows/` here but not in `standard/workflows/`, so its PR fails `make test` (the copies must match). On that PR's branch run `cp .github/workflows/{pr-title,label-guard,todo-issues}.yml standard/workflows/`, commit and push; `make check` then passes and the next `apply workflows` ships the new pins.

## Rollback
Delete the ruleset: `gh api -X DELETE repos/giocaizzi/<repo>/rulesets/<id>` (id from `gh api repos/giocaizzi/<repo>/rulesets`). Settings and labels are additive and need no rollback.

## Scheduled audit
`.github/workflows/audit.yml` runs weekly with `--visibility public`, uploads `audit.json` as the artifact `audit` (kept 90 days) and opens or updates a `drift` issue; both are public, so they cover public repos only. Private repos are audited locally with `--visibility private`; their results are never stored on GitHub. It needs the `AUDIT_TOKEN` secret (fine-grained PAT, read-only Administration, Contents, Issues, Secrets and Metadata; Secrets lists names only, for the repository-secret check on all repos).

The dashboard fetches the latest public JSON from here and audits private repos itself with the owner's `gh` login (`scripts/sync.sh audit --json --visibility private`):
```bash
url=$(gh api 'repos/giocaizzi/.github/actions/artifacts?name=audit&per_page=1' -q '.artifacts[0].archive_download_url')
gh api "$url" > audit.zip && unzip -p audit.zip audit.json
``` Apply modes: `scripts/sync.sh apply settings|labels|ruleset [repo ...]`.
