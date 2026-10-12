# .github

Canonical GitHub standard for every giocaizzi repository, plus the read-only audit that measures drift.

- Standard (source of truth): [docs/standard.md](docs/standard.md)
- Rollout and audit procedure: [docs/runbook-rollout.md](docs/runbook-rollout.md)
- Machine-readable standard: `standard/` (labels, ruleset, repo settings, repo types in `repos.yaml`)
- Org-wide `SECURITY.md` and `.github/ISSUE_TEMPLATE/` here are inherited by every repo.
- `make audit` reports drift for all repos (`make audit JSON=1` for the dashboard JSON; the weekly run uploads it as artifact `audit`, see the runbook); `make onboard REPO=<name>` applies the standard to a new repo (created from `giocaizzi/template`); `make check` = lint + test.

Gotchas
- `greenhouse` is the reference implementation; change the standard here first, then the repos.
- Never apply the ruleset to a repo that lacks a `check` job: it blocks every merge.
- Every repo must be listed in `standard/repos.yaml`; the audit fails an unlisted one.
