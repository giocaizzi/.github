# Runbook: audit and roll out the standard

Prereqs: `gh` authenticated with `repo` + `administration` scope, `jq`, `shellcheck`.

## Audit (read-only)
```bash
make audit                      # all in-scope repos
scripts/sync.sh audit greenhouse # one repo
```
Exit code 1 when any repo drifts. Output lists each deviation.

## New repo
1. Create it from the template: `gh repo create giocaizzi/<name> --template giocaizzi/template --public --clone` (starts with CI `check`, PR-title and label-guard workflows, Dependabot, Makefile, AGENTS.md + CLAUDE.md).
2. `make onboard REPO=<name>` here: applies settings, labels and workflows, applies the ruleset once `check` is green on the default branch, then audits the repo.
3. If it printed "ruleset not applied", merge any open PRs, wait for `check` on the default branch, then `scripts/sync.sh apply ruleset <name>`.

## Apply, in this order (low risk first)
1. **Settings**: `gh api -X PATCH repos/giocaizzi/<repo> --input standard/repo-settings.json`.
2. **Labels**: `gh label create <name> --color <hex> --description <text> --force -R giocaizzi/<repo>` for each entry in `standard/labels.yaml`.
3. **Workflows**: `scripts/sync.sh apply workflows <repo>` opens a PR with `standard/workflows/*` (PR title check); merge it.
4. **CI**: land a `check` job (and `make check`) in the repo first, via PR.
5. **Ruleset**: only after `check` and `Validate PR title` have run green once: `gh api repos/giocaizzi/<repo>/rulesets --method POST --input standard/ruleset-main.json`. Applying earlier blocks every merge.
6. Re-run the audit; it must report `ok` for the repo.

## Rollback
Delete the ruleset: `gh api -X DELETE repos/giocaizzi/<repo>/rulesets/<id>` (id from `gh api repos/giocaizzi/<repo>/rulesets`). Settings and labels are additive and need no rollback.

## Scheduled audit
`.github/workflows/audit.yml` runs weekly and opens or updates a `drift` issue. It needs the `AUDIT_TOKEN` secret (fine-grained PAT, read-only Administration + Metadata on all repos). Apply modes: `scripts/sync.sh apply settings|labels|ruleset [repo ...]`.
