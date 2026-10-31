# .github

Canonical GitHub standard for every giocaizzi repository, plus the read-only audit that measures drift.

- Standard (source of truth): [docs/standard.md](docs/standard.md)
- Rollout and audit procedure: [docs/runbook-rollout.md](docs/runbook-rollout.md)
- Machine-readable standard: `standard/` (labels, ruleset, repo settings); repo type and flags are GitHub topics on each repo (`std-<type>`, `std-<flag>`, parsed by `scripts/meta.jq`)
- Org-wide `SECURITY.md` and `.github/ISSUE_TEMPLATE/` here are inherited by every repo.
- `make audit` reports drift (`VISIBILITY=public|private`, `JSON=1` for the dashboard JSON; the weekly run here audits public repos only and uploads artifact `audit`, see the runbook); `make onboard REPO=<name> TYPE=<type> [FLAGS=released,pypi]` sets the topics and applies the standard to a new repo (created from `giocaizzi/template`); `make check` = lint + test.

Gotchas
- `greenhouse` is the reference implementation; change the standard here first, then the repos.
- Never apply the ruleset to a repo that lacks a `check` job: it blocks every merge.
- Every repo needs exactly one `std-<type>` topic; the audit fails it otherwise.
- The workflow checker is `scripts/workflow.py` (uv, `ruamel.yaml` pinned in its header); after changing that pin, run `uv lock --script scripts/workflow.py`. `scripts/workflow.awk` only blanks or replaces refs (text modes).
- This repo is public: never name a private repo or include private data in files, issues, PRs or artifacts here.
