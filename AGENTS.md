# .github

Canonical GitHub standard for every giocaizzi repository, plus the read-only audit that measures drift.

- Standard (source of truth): [docs/standard.md](docs/standard.md)
- Rollout and audit procedure: [docs/runbook-rollout.md](docs/runbook-rollout.md)
- Machine-readable standard: `standard/` (labels, ruleset, repo settings)
- `make audit` reports drift for all repos; `make check` = lint + test.

Gotchas
- `greenhouse` is the reference implementation; change the standard here first, then the repos.
- Never apply the ruleset to a repo that lacks a `check` job: it blocks every merge.
