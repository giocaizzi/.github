# Standard drift

Audit of 2026-01-05: 2 repos checked, 1 drifted, 1 with unknown checks, 0 ok. [Run](https://github.com/acme/audit/actions/runs/1).

## Drift

| check | repo | found | wanted | status |
| --- | --- | --- | --- | --- |
| tooling:mypy | acme-app | - | 2.4.0 | drift |

## Unknown (cannot read)

These are not drift: the audit token could not read them (for example HTTP 403). Widen the token's read scope (see docs/runbook-rollout.md#scheduled-audit).

| check | repo | found | wanted | status |
| --- | --- | --- | --- | --- |
| tooling:golangci-lint | acme-lib | - | 2.5 | unknown |

## How to fix

| check | fix |
| --- | --- |
| tooling:golangci-lint | see docs/tooling.md |
| tooling:mypy | see docs/tooling.md |

## Tooling

<details><summary>Tooling inventory (informational)</summary>

Status: same = as expected, differs = not the expected value, absent = not present, n.a. = does not apply, unknown = could not be read. `warn:` = worth a look, `FAIL:` = drift (listed above).

### Common

| repo | uv |
| --- | --- |
| acme-app | 0.11.2 (same) |
| acme-lib | 0.10.0 (differs) |

### Python

| repo | mypy | ruff |
| --- | --- | --- |
| acme-app | FAIL: - (absent) | warn: 0.16.0 (differs) |

### Go

| repo | golangci-lint |
| --- | --- |
| acme-lib | FAIL: - (unknown) |

</details>
