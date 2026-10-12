# GitHub standard

Applies to all non-fork, non-archived repositories of `giocaizzi`. Reference implementation: `giocaizzi/greenhouse`. Machine-readable parts live in `standard/`.

## Pull requests
- `main` changes only through a PR that passed CI; no bypass actors, no force-push, no deletion.
- Squash merge only; title is a Conventional Commit (it becomes the commit and drives release-please).
- Auto-merge on; branch deleted on merge. Stacked PRs with `gh stack` for layered work.
- Review threads must be resolved; approvals 0 while solo.

## Ruleset (`standard/ruleset-main.json`)
Default-branch rules: PR required (squash), up-to-date branch, required status check `check`, no deletion or force-push. `check` is one aggregate CI job (`needs: [...]`, `if: always()`) so job renames never touch the ruleset. No merge queue on user-owned repos (not offered); strict up-to-date checks plus auto-merge replace it.

## Repo settings (`standard/repo-settings.json`)
Squash only, auto-merge, delete-branch-on-merge, secret scanning and push protection on. Dependabot updates configured per repo (`.github/dependabot.yml`: ecosystem + `github-actions`).

## Labels (`standard/labels.yaml`)
Type (bug, enhancement, documentation, question, wontfix, duplicate), priority P1–P3, `parity`, and the automation labels Dependabot and release-please create. Extras in a repo are tolerated; missing ones are drift.

## CI and releases
- One `ci.yml` per repo, plain (no reusable workflows; `giocaizzi/actions` is retired). Python: `uv`, ruff, mypy, pytest. Every repo exposes `make help|lint|test|check` and CI runs `make check`.
- Releases via release-please with a GitHub App token (so the release PR triggers CI). Tags `v*`.
- Python tooling is `uv` only; no poetry.

## Security
Secret scanning + push protection on every public repo (private repos need GHAS, so they skip it); CI adds gitleaks on all. Security policy in `SECURITY.md` (inherited from this repo).

## Per-repo docs
Each repo has `AGENTS.md` (+ `CLAUDE.md` symlink) and `docs/`; this standard is linked, not copied.

## Private repos on the free plan
Rulesets, branch protection, auto-merge and secret scanning are unavailable (GitHub returns 403/422). Private repos keep everything else: squash-only, delete-on-merge, labels, a `check` CI job with gitleaks, and the PR-only convention enforced by `AGENTS.md`. Moving to GitHub Pro or making a repo public lifts this; then rerun `sync.sh apply`.
