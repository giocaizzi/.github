# GitHub standard

Applies to all non-fork, non-archived repositories of `giocaizzi`. Reference implementation: `giocaizzi/greenhouse`. Machine-readable parts live in `standard/`.

## Pull requests
- `main` changes only through a PR that passed CI; no bypass actors, no force-push, no deletion.
- Squash merge only. The squash commit is built from the PR, never from branch commits: title = PR title (`squash_merge_commit_title: PR_TITLE`), body = PR description (`squash_merge_commit_message: PR_BODY`). Branch commit messages are history only.
- PR title is a Conventional Commit header, `type(scope): lowercase description`; it is the commit on `main` and drives release-please. Required check `Validate PR title` (`standard/workflows/pr-title.yml`) enforces it in CI; the agent-mods title guard enforces it before `gh pr create` / `git commit` run.
- PR description follows `.github/PULL_REQUEST_TEMPLATE.md` (What / Why / Verification), then footers as plain trailing lines: `BREAKING CHANGE:`, `Refs:`, attribution.
- Auto-merge on; branch deleted on merge. Stacked PRs with `gh stack` for layered work.
- Review threads must be resolved; approvals 0 while solo.

## Attribution
Who wrote a change must survive the squash, so attribution lives in the PR description:
- **AI-authored or co-authored work**: one `Co-Authored-By:` trailer per model that actually wrote code in the PR, naming that model exactly as the harness reports it (e.g. `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`), never a guessed or configured name. Subagents on another model add their own trailer. The description ends with the harness's generated-by line (Claude Code: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`; Copilot CLI: its own co-author trailer).
- **Bots** (Dependabot, release-please) attribute themselves; leave them as they are.
- **Human-only work**: no trailer.
- Branch commits carry the same trailer, but only the PR description reaches `main`.

## Ruleset (`standard/ruleset-main.json`)
Default-branch rules: PR required (squash), up-to-date branch, required status checks `check` and `Validate PR title`, no deletion or force-push. `check` is one aggregate CI job (`needs: [...]`, `if: always()`) so job renames never touch the ruleset. No merge queue on user-owned repos (not offered); strict up-to-date checks plus auto-merge replace it.

## Repo settings (`standard/repo-settings.json`)
Squash only, auto-merge, delete-branch-on-merge, secret scanning and push protection on. Dependabot updates configured per repo (`.github/dependabot.yml`: ecosystem + `github-actions`).

## Labels (`standard/labels.yaml`)
Type (bug, enhancement, documentation, question, wontfix, duplicate), priority P1–P3, `parity`, and the automation labels Dependabot and release-please create. Only standard labels may exist: `sync.sh apply labels` deletes extras and the `label-guard` workflow (`standard/workflows/label-guard.yml`) deletes a non-standard label as soon as it is created or renamed. To add a label, change `standard/labels.yaml` here first. GitHub cannot block label creation natively.

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
