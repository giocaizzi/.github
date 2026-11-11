# Standard drift

Audit of 2026-01-05: 1 repos checked, 1 drifted, 0 with unknown checks, 0 ok. [Run](https://github.com/acme/audit/actions/runs/1).

## Drift

| check | repo | found | wanted | status |
| --- | --- | --- | --- | --- |
| wf_pinned | acme-app | ci.yml: actions/checkout@v4 is not pinned by full SHA (x3)<br>ci.yml: actions/cache@v3 is not pinned by full SHA<br>release.yml: owner/act1@v1 lacks a version comment<br>release.yml: owner/act2@v1 lacks a version comment<br>release.yml: owner/act3@v1 lacks a version comment<br>release.yml: owner/act4@v1 lacks a version comment<br>release.yml: owner/act5@v1 lacks a version comment<br>release.yml: owner/act6@v1 lacks a version comment<br>... and 2 more | every uses: pinned by full SHA with a version comment | drift |
| wf_timeout | acme-app | ci.yml: job a \| b has no timeout-minutes | timeout-minutes on every job | drift |

## How to fix

| check | fix |
| --- | --- |
| wf_pinned | by hand via PR: docs/standard.md#ci-hygiene |
| wf_timeout | by hand via PR: docs/standard.md#ci-hygiene |
