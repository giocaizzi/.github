# Runbook: audit and roll out the standard

Prereqs: `gh` authenticated with `repo` + `administration` scope, `jq`, `shellcheck`.

## Audit (read-only)
```bash
make audit                      # all in-scope repos (VISIBILITY=public|private to narrow)
scripts/sync.sh audit greenhouse # one repo
```
Exit code 0 ok, 1 when any repo drifts (a failing standard or typed check), 2 when no repo is in scope. Output lists each failing check as `id: detail`.

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
3. **Workflows**: `scripts/sync.sh apply workflows <repo>` opens a PR with `standard/workflows/*` (PR title check); merge it.
   Once the PR with `todo-issues.yml` is merged, `scripts/sync.sh apply todos <repo>` imports the repo's existing TODOs as `todo` issues (safe to rerun: titles are deduplicated).
4. **Agent ignore**: `scripts/sync.sh apply gitignore <repo>` opens a PR appending the missing `standard/gitignore-agents` lines to `.gitignore`; merge it.
5. **CI**: land a `check` job (and `make check`) in the repo first, via PR.
6. **Ruleset**: only after `check` and `Validate PR title` have run green once: `gh api repos/giocaizzi/<repo>/rulesets --method POST --input standard/ruleset-main.json`. Applying earlier blocks every merge.
7. Re-run the audit; it must report `ok` for the repo.

## Rollback
Delete the ruleset: `gh api -X DELETE repos/giocaizzi/<repo>/rulesets/<id>` (id from `gh api repos/giocaizzi/<repo>/rulesets`). Settings and labels are additive and need no rollback.

## Scheduled audit
`.github/workflows/audit.yml` runs weekly with `--visibility public`, uploads `audit.json` as the artifact `audit` (kept 90 days) and opens or updates a `drift` issue; both are public, so they cover public repos only. Private repos are audited locally with `--visibility private`; their results are never stored on GitHub. It needs the `AUDIT_TOKEN` secret (fine-grained PAT, read-only Administration, Contents, Issues, Secrets and Metadata; Secrets lists names only, for the repository-secret check on all repos).

The dashboard fetches the latest public JSON from here and audits private repos itself with the owner's `gh` login (`scripts/sync.sh audit --json --visibility private`):
```bash
url=$(gh api 'repos/giocaizzi/.github/actions/artifacts?name=audit&per_page=1' -q '.artifacts[0].archive_download_url')
gh api "$url" > audit.zip && unzip -p audit.zip audit.json
``` Apply modes: `scripts/sync.sh apply settings|labels|ruleset [repo ...]`.
