# Standard drift

Audit of 2026-01-05: 3 repos checked, 2 drifted, 0 with unknown checks, 1 ok. [Run](https://github.com/acme/audit/actions/runs/1).

## Drift

| check | repo | found | wanted | status |
| --- | --- | --- | --- | --- |
| delete_branch | acme-app | delete_branch_on_merge: false | delete_branch_on_merge: true | drift |
| delete_branch | acme-lib | delete_branch_on_merge: false | delete_branch_on_merge: true | drift |
| labels | acme-app | missing: bug, feature<br>extra: wontfix | the standard labels (plus the repo extras), no others | drift |
| squash_only | acme-app | allow_merge_commit: true<br>allow_rebase_merge: true<br>squash_merge_commit_title: COMMIT_OR_PR_TITLE | allow_merge_commit: false<br>allow_rebase_merge: false<br>squash_merge_commit_title: PR_TITLE | drift |

## How to fix

| check | fix |
| --- | --- |
| delete_branch | `scripts/sync.sh apply settings <repo>` |
| labels | `scripts/sync.sh apply labels <repo>` |
| squash_only | `scripts/sync.sh apply settings <repo>` |
