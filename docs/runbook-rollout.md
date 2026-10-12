# Runbook: audit and roll out the standard

Prereqs: `gh` authenticated with `repo` + `administration` scope, `jq`, `shellcheck`.

## Audit (read-only)
```bash
make audit                      # all in-scope repos
scripts/sync.sh audit greenhouse # one repo
```
Exit code 1 when any repo drifts. Output lists each deviation.

## Apply, in this order (low risk first)
1. **Settings**: `gh api -X PATCH repos/giocaizzi/<repo> --input standard/repo-settings.json`.
2. **Labels**: `gh label create <name> --color <hex> --description <text> --force -R giocaizzi/<repo>` for each entry in `standard/labels.yaml`.
3. **CI**: land a `check` job (and `make check`) in the repo first, via PR.
4. **Ruleset**: only after `check` has run green once: `gh api repos/giocaizzi/<repo>/rulesets --method POST --input standard/ruleset-main.json`. Applying earlier blocks every merge.
5. Re-run the audit; it must report `ok` for the repo.

## Rollback
Delete the ruleset: `gh api -X DELETE repos/giocaizzi/<repo>/rulesets/<id>` (id from `gh api repos/giocaizzi/<repo>/rulesets`). Settings and labels are additive and need no rollback.
