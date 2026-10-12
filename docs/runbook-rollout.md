# Runbook: audit and roll out the standard

Prereqs: `gh` authenticated with `repo` + `administration` scope, `jq`, `shellcheck`.

## Audit (read-only)
```bash
make audit                      # all in-scope repos
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
1. Create it from the template: `gh repo create giocaizzi/<name> --template giocaizzi/template --public --clone` (starts with CI `check`, PR-title and label-guard workflows, Dependabot, Makefile, AGENTS.md + CLAUDE.md, LICENSE).
2. Add it to `standard/repos.yaml` here (`type`, `released`; `pypi: true` for a PyPI package, `deploys: true` for publish/deploy jobs) via PR; the audit fails an unlisted repo.
3. `make onboard REPO=<name>` here: applies settings, labels and workflows, applies the ruleset once `check` is green on the default branch, then audits the repo.
4. If it printed "ruleset not applied", merge any open PRs, wait for `check` on the default branch, then `scripts/sync.sh apply ruleset <name>`.

## PyPI trusted publisher (one-time, manual, per project)
On pypi.org, project > Publishing > add a GitHub trusted publisher: owner `giocaizzi`, repository, workflow file name (e.g. `python-publish.yml`), environment `pypi`. For a project not yet on PyPI, add a pending publisher under the account's Publishing page. Then create the `pypi` environment in the repo (Settings > Environments), delete any `PYPI_API_TOKEN` repository secret, and make the workflow `id-token: write` + `environment: pypi` with no token. Deploy secrets move to the deploy job's environment the same way. `scripts/sync.sh audit <repo>` must report `environments` and `pypi_publish` as passing.

## Apply, in this order (low risk first)
1. **Settings**: `scripts/sync.sh apply settings <repo>` (repo settings; secret scanning and private vulnerability reporting on public repos).
2. **Labels**: `gh label create <name> --color <hex> --description <text> --force -R giocaizzi/<repo>` for each entry in `standard/labels.yaml`.
3. **Workflows**: `scripts/sync.sh apply workflows <repo>` opens a PR with `standard/workflows/*` (PR title check); merge it.
4. **CI**: land a `check` job (and `make check`) in the repo first, via PR.
5. **Ruleset**: only after `check` and `Validate PR title` have run green once: `gh api repos/giocaizzi/<repo>/rulesets --method POST --input standard/ruleset-main.json`. Applying earlier blocks every merge.
6. Re-run the audit; it must report `ok` for the repo.

## Rollback
Delete the ruleset: `gh api -X DELETE repos/giocaizzi/<repo>/rulesets/<id>` (id from `gh api repos/giocaizzi/<repo>/rulesets`). Settings and labels are additive and need no rollback.

## Scheduled audit
`.github/workflows/audit.yml` runs weekly, uploads `audit.json` as the artifact `audit` (kept 90 days) and opens or updates a `drift` issue. It needs the `AUDIT_TOKEN` secret (fine-grained PAT, read-only Administration, Contents, Issues and Metadata on all repos).

The dashboard fetches the latest JSON:
```bash
url=$(gh api 'repos/giocaizzi/.github/actions/artifacts?name=audit&per_page=1' -q '.artifacts[0].archive_download_url')
gh api "$url" > audit.zip && unzip -p audit.zip audit.json
``` Apply modes: `scripts/sync.sh apply settings|labels|ruleset [repo ...]`.
