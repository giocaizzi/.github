# GitHub standard

Applies to all non-fork, non-archived repositories of `giocaizzi`. Reference implementation: `giocaizzi/greenhouse`. Machine-readable parts live in `standard/`. `scripts/sync.sh audit` checks every rule below (see [Audit](#audit)).

## New repos
Start from `giocaizzi/template` and run `make onboard REPO=<name> TYPE=<type> [FLAGS=...]`, which sets the repo's [topics](#repo-types-topics) and applies the standard (runbook: [runbook-rollout.md](runbook-rollout.md)). Nothing in GitHub applies this standard automatically on a personal account; the weekly audit flags any repo that skipped it.

## Pull requests
- `main` changes only through a PR that passed CI; no bypass actors, no force-push, no deletion.
- Squash merge only. The squash commit is built from the PR, never from branch commits: title = PR title (`squash_merge_commit_title: PR_TITLE`), body = PR description (`squash_merge_commit_message: PR_BODY`). Branch commit messages are history only.
- PR title is a Conventional Commit header, `type(scope): lowercase description`; it is the commit on `main` and drives release-please. Required check `Validate PR title` (`standard/workflows/pr-title.yml`) enforces it in CI; the `guard` plugin of `giocaizzi/harness` enforces it before `gh pr create` / `git commit` run.
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
Squash only, auto-merge, delete-branch-on-merge, secret scanning and push protection, private vulnerability reporting (the last four on public repos only). Dependabot updates configured per repo (`.github/dependabot.yml`: ecosystem + `github-actions`), always grouped, never one PR per dependency: every `updates` entry has `groups`. `github-actions` and `docker`: one group, `patterns: ["*"]`. Language ecosystems (uv, pip, npm, ...): `minor-patch` (`update-types: [minor, patch]`), `major` (`update-types: [major]`) and `security` (`applies-to: security-updates`, `patterns: ["*"]`). Every `updates` entry sets `commit-message.prefix` so Dependabot PR titles pass the `Validate PR title` check: `ci(deps)` for `github-actions`, `chore(deps)` for every other ecosystem (no `include: scope`). Dependabot lowercases `bump` after a lowercase prefix unless the latest Dependabot commit on the default branch starts `type: Bump`; then it copies that capital, and the title of such a PR is edited to lowercase before merging.

## Labels (`standard/labels.yaml`)
Type (bug, enhancement, documentation, question, wontfix, duplicate), priority P1–P3, `parity`, and the automation labels Dependabot and release-please create. Only standard labels may exist: `sync.sh apply labels` deletes extras and the `label-guard` workflow (`standard/workflows/label-guard.yml`) deletes a non-standard label as soon as it is created or renamed. To add a label, change `standard/labels.yaml` here first. GitHub cannot block label creation natively.

## CI and releases
- One `ci.yml` per repo, plain (no reusable workflows). Python: `uv`, ruff, mypy, pytest; new projects start with ruff `select = ["ALL"]` and Google docstrings (`pydocstyle` `convention = "google"`). Every repo exposes `make help|lint|test|check` and CI runs `make check`.
- Releases via release-please with a GitHub App token (so the release PR triggers CI). Tags `v*`.
- Python tooling is `uv` only; no poetry.

## Bots
Scheduled bots never push to the default branch. They write to a fixed branch, open a PR with a Conventional Commit title and arm auto-merge, authenticated with the release-please GitHub App token (`RP_APP_ID` / `RP_APP_KEY` secrets, `actions/create-github-app-token`) so CI runs on the PR; `GITHUB_TOKEN` PRs do not trigger workflows. Reference: `btc-cycles` `.github/workflows/run.yml`. Known exceptions, listed in `standard/ruleset-exceptions.txt` when public: `giocaizzi` (profile README; the daily stats bot pushes `main` directly, so the repo has no `main` ruleset). A private repo whose bot or app sync pushes `main` directly needs no entry: private repos have no ruleset on the free plan.

## Coverage
Coverage is reporting, never a gate: the only required checks are `check` and `Validate PR title`. Repos that upload to Codecov ship a `codecov.yml` with `informational: true` for project and patch statuses.

## Tests that cannot run in CI
Tests that need the network or live data get a `network` pytest marker and are deselected by `make test`; tests broken by upstream drift become `xfail(strict=True)` with a reason pointing at a tracking issue. Never merge a red `check`.

## Security
Secret scanning + push protection on public repos only (private repos need GHAS); CI runs gitleaks on all. `SECURITY.md` (report through GitHub private vulnerability reporting, enabled on public repos) and the issue forms in `.github/ISSUE_TEMPLATE/` (bug, feature) live in this repo and are inherited by every repo as community health defaults; a repo's own file replaces them.

## License
Every public repo has a `LICENSE` (MIT unless stated otherwise).

## README
`README.md` is for humans. Agent instructions live only in `AGENTS.md`, never in the README; the README never duplicates `docs/`. Reference layout: `py3dinterpolations` and `btc-cycles`: a centered `<div align="center">` header (optional logo, `# name`, bold one-line tagline, one row of linked shields.io / GitHub workflow badges, `</div>`), `---`, a short description, a quickstart code block, features, a link to `docs/`, a license line. `giocaizzi/template` ships the skeleton. Documented only, not audited.

Badges are added progressively, in the order PyPI, Python, CI, Coverage, Docs, Ruff, License:
- **Every repo**: header, tagline, CI badge (`ci.yml`) and License badge, description, quickstart, link to `docs/`, license line.
- **Public**: plus a language/tooling badge where it applies (e.g. Ruff for Python).
- **Released**: plus the latest release badge; for PyPI packages the PyPI version and Python versions badges, and install from PyPI in the quickstart.
- **Docs site or coverage live**: plus a Docs badge linking the site and a Coverage (Codecov) badge; optional logo (`assets/logo.png`) and a screenshot or plot when the output is visual.

## Environments and publishing
Every workflow job that publishes or deploys runs in a named GitHub environment (`pypi` for PyPI, `production` or `<target>` for deploys), and its secrets are environment secrets, not repository secrets. PyPI publishing uses trusted publishing (OIDC, no token), triggered by the release.

Environments and environment secrets are available on public repos on every plan; private repos need GitHub Pro, Team or Enterprise ([docs](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)). On the free plan the checks `environments` and `pypi_publish` therefore apply to public repos only (private ones list them under `exempt`).

## Per-repo docs
Each repo has `AGENTS.md` (+ `CLAUDE.md` symlink to it, tracked as a git symlink) and `docs/`; this standard is linked, not copied.

## Agent config
Shared agent config is committed; personal and machine state is not. The repo's own `.gitignore` carries the ignore block, since a global excludes file reaches neither other clones nor CI. `giocaizzi/template` ships it. Documented only, not audited.

- **Track:** `AGENTS.md`, `CLAUDE.md`; `.claude/` (`settings.json`, `agents`, `commands`, `skills`, `rules`, `output-styles`, `workflows`, `agent-memory`); `.mcp.json`; `.worktreeinclude`; `.github/` (`copilot-instructions.md`, `instructions`, `agents`, `skills`, `prompts`, `hooks`, `mcp.json`, `copilot/settings.json`); `.vscode/settings.json`, `.vscode/mcp.json`; `.codex/`; `.agents/skills`, `skills-lock.json`; `opencode.json(c)`, `.opencode/`; `.pi/` (`settings.json`, `mcp.json`, `extensions`, `skills`, `prompts`, `themes`).
- **Ignore:**

```gitignore
# AI coding agents: personal and machine state (shared config is tracked)
.claude/settings.local.json
.claude/worktrees/
.claude/agent-memory-local/
CLAUDE.local.md
.github/copilot/settings.local.json
.opencode/node_modules/
.opencode/plans/
.pi/npm/
.pi/git/
```

Worktrees: Claude Code creates them inside the repo (`.claude/worktrees/`, hence the entry); Copilot CLI, Codex and opencode create them outside it. opencode also writes `.opencode/.gitignore` for its own dependencies. Sources: [Claude Code](https://code.claude.com/docs/en/claude-directory), [Copilot CLI](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference), [VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-instructions), [Codex](https://learn.chatgpt.com/docs/agent-configuration/agents-md), [opencode](https://opencode.ai/docs/config), [pi](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/configuration.md).

## Repo types (topics)
Each repo carries its metadata as GitHub topics, so no list of repos lives here: exactly one `std-<type>` (`std-python`, `std-typescript`, `std-infra`, `std-config`, `std-docs`), plus the flags `std-released` (ships versioned releases), `std-pypi` (published on PyPI) and `std-deploys` (has publish/deploy jobs), and `std-exception-<check>` for a documented [exception](#exceptions) (check id with `-` for `_`, e.g. `std-exception-claude-symlink`). The type decides which typed rules apply; `std-pypi` and `std-deploys` switch on the checks in [Environments and publishing](#environments-and-publishing). `make onboard` sets them; change them with `gh repo edit giocaizzi/<repo> --add-topic|--remove-topic`. `scripts/meta.jq` parses them.

## Audit
`scripts/sync.sh audit` reports three kinds of checks; standard and typed failures are drift (exit 1), extras never are.
- **Standard** (every repo): exactly one `std-<type>` topic (`repo_type`); `ci.yml` job `check` with `needs` + `if: always()`; Makefile `check` target; gitleaks in `ci.yml`; standard `pr-title` and `label-guard` workflows; Dependabot with grouped updates and a Conventional Commit `commit-message.prefix` on every entry; `AGENTS.md` + `CLAUDE.md` symlink; squash-only, delete-branch; no poetry; labels; `SECURITY.md` and issue templates (own or inherited); on public repos also auto-merge, `main` ruleset, secret scanning, private vulnerability reporting and `LICENSE`.
- **Typed** (when applicable): tests (python, typescript); `uv.lock` + ruff + mypy + pytest (python); hadolint in `ci.yml` or Makefile (any Dockerfile); a validate step (infra); `release-please-config.json` (released), plus `uv.lock` in its `extra-files` when the repo has one (`uv_lock_release`: release-please does not bump the version `uv.lock` records; select each `[[package]]` with `$.package[?(@.name.value=='<name>')].version`); `informational: true` (when `codecov.yml` exists); `environments` and `pypi_publish` (public repos only).
  - `environments` (`deploys: true` or `pypi: true`): every job in `.github/workflows/*.yml` with a publish/deploy step declares `environment:`. A step counts as publish/deploy when the job contains `gh-action-pypi-publish`, `uv publish`, `docker push`, `deploy-pages`, `cosign sign`, `wrangler deploy`, a `/webhooks/` call, `scp`/`rsync`/`ssh`, or `docker/build-push-action` with `push: true`. Repository secrets named like `PYPI|DEPLOY|PORTAINER|WEBHOOK|SSH|REGISTRY|DOCKER` also fail it (names only).
  - `pypi_publish` (`pypi: true`): `release-please-config.json` plus a workflow that publishes with `pypa/gh-action-pypi-publish` or `uv publish`, `id-token: write`, no token, `environment: pypi`, triggered by `release:` or a release-please output.
- **Extras** (presence only): pre-commit, CODEOWNERS, changelog, Dockerfile, live docs site (GitHub Pages or a homepage URL), plus tests, Terraform and `LICENSE` where not required.

`--json` emits one object per repo (checks, extras, exemptions, scores). `--visibility public|private|all` (default `all`) limits the scope. This repo is public, so its weekly audit runs `--visibility public` and its `audit` artifact and `drift` issue cover public repos only; private repos are audited locally (the owner's dashboard runs `sync.sh audit --json --visibility private` with the owner's `gh` login), so nothing about them is stored on GitHub, and no private repo is named here.

## Exceptions
- `giocaizzi` (profile bot) pushes `main` directly: no `main` ruleset (see [Bots](#bots)).
- Private repos on the free plan: no ruleset, auto-merge or secret scanning (see below); the audit lists those checks under `exempt`.
- `rp5-homeserver`: Portainer rejects tracked symlinks, so `CLAUDE.md` is an untracked local symlink and `.gitignore` lists `/CLAUDE.md`; the audit accepts `AGENTS.md` + that entry (topic `std-exception-claude-symlink`).

## Private repos on the free plan
Rulesets, branch protection, auto-merge and secret scanning are unavailable (GitHub returns 403/422). Private repos keep everything else: squash-only, delete-on-merge, labels, a `check` CI job with gitleaks, and the PR-only convention enforced by `AGENTS.md`. Moving to GitHub Pro or making a repo public lifts this; then rerun `sync.sh apply`.
