# Standard drift

Audit of 2026-01-05: 1 repos checked, 0 drifted, 1 with unknown checks, 0 ok. [Run](https://github.com/acme/audit/actions/runs/1).

## Unknown (cannot read)

These are not drift: the audit token could not read them (for example HTTP 403). Widen the token's read scope (see docs/runbook-rollout.md#scheduled-audit).

| check | repo | found | wanted | status |
| --- | --- | --- | --- | --- |
| ruleset_main | acme-app | HTTP 403 | ruleset main with the required checks | unknown |
| secret_scanning | acme-app | HTTP 403 | secret scanning and push protection enabled | unknown |

## How to fix

| check | fix |
| --- | --- |
| ruleset_main | `scripts/sync.sh apply ruleset <repo>` (after a green check) |
| secret_scanning | `scripts/sync.sh apply settings <repo>` |
