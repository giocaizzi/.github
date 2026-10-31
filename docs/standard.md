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
Default-branch rules: PR required (squash), up-to-date branch, required status checks `check` and `Validate PR title` (a minimum: a repo may require more, e.g. a leak check; the audit and `sync.sh apply ruleset` keep them), no deletion or force-push. `check` is one aggregate CI job (`needs: [...]`, `if: always()`) so job renames never touch the ruleset. No merge queue on user-owned repos (not offered); strict up-to-date checks plus auto-merge replace it.

## Repo settings (`standard/repo-settings.json`)
Squash only, auto-merge, delete-branch-on-merge, secret scanning and push protection, private vulnerability reporting (the last four on public repos only). Dependabot alerts and Dependabot security updates on every repo (free on private repos too; `sync.sh apply settings` enables them through their own endpoints, not `repo-settings.json`). Dependabot updates configured per repo (`.github/dependabot.yml`: ecosystem + `github-actions`), always grouped, never one PR per dependency: every `updates` entry has `groups`. `github-actions` and `docker`: one group, `patterns: ["*"]`. Language ecosystems (uv, pip, npm, gomod, ...): `minor-patch` (`update-types: [minor, patch]`), `major` (`update-types: [major]`) and `security` (`applies-to: security-updates`, `patterns: ["*"]`). Every `updates` entry sets `commit-message.prefix` so Dependabot PR titles pass the `Validate PR title` check: `ci(deps)` for `github-actions`, `chore(deps)` for every other ecosystem (no `include: scope`). Dependabot lowercases `bump` after a lowercase prefix unless the latest Dependabot commit on the default branch starts `type: Bump`; then it copies that capital, and the title of such a PR is edited to lowercase before merging.

## Labels (`standard/labels.yaml`)
Type (bug, enhancement, documentation, question, wontfix, invalid, duplicate), priority P1–P3, `parity`, and the automation labels Dependabot, release-please and the `todo-issues` workflow create. A repo may declare its own extra labels in `.github/labels.yaml` (same format, optional; this repo's holds `drift`); an extra that reuses a standard name is ignored and fails the audit. No other label may exist: `sync.sh apply labels` creates the standard and the repo's extras and deletes the rest, and the `label-guard` workflow (`standard/workflows/label-guard.yml`) deletes any other label as soon as it is created or renamed. A label every repo needs goes in `standard/labels.yaml` here; one only a repo needs goes in that repo's `.github/labels.yaml`. GitHub cannot block label creation natively.

## TODO tracking
Every repo runs `standard/workflows/todo-issues.yml` (`alstr/todo-to-issue-action`): a push to the default branch that adds a `TODO` comment opens an issue labelled `todo`, and removing the comment closes it. It triggers on pushes to `main` or `master` only (the default branch names in use; `on.push.branches` cannot read the default branch), plus manual dispatch, and its job-level `if` keeps it to the default branch, so pushes to other branches start no run. A default branch with another name fails the audit (`todo_issues_branch`). It reads the push diff only; to import the TODOs a repo already has, `sync.sh apply todos <repo>` runs it once by hand over the whole history (an issue with the same title, open or closed, is never duplicated).

## CI and releases
- One `ci.yml` per repo, plain (no reusable workflows). Python: `uv`, ruff, mypy, pytest; new projects start with ruff `select = ["ALL"]` and Google docstrings (`pydocstyle` `convention = "google"`). Every repo exposes `make help|lint|test|check` and CI runs `make check`.
- Releases via release-please with a GitHub App token (so the release PR triggers CI). Tags `v*`.
- Python tooling is `uv` only; no poetry.
- Go (`std-go`): module at the repo root (`go.mod`, its `go` line pins the toolchain CI uses). The recipe below; versions checked on 2026-10-20. Dependabot bumps the action refs (`github-actions`) and `go.mod` (`gomod`), but not the golangci-lint `version:` input or the govulncheck `@v` pin in the Makefile: bump those two by hand.
  - Makefile: `lint` runs `go vet ./...`, `golangci-lint run` and `go run golang.org/x/vuln/cmd/govulncheck@v1.9.0 ./...`; `test` runs `go test -race ./...`.
  - `ci.yml`: the `check` job installs the toolchain before `make check`, so CI still calls only the Makefile:
    ```yaml
          - uses: actions/setup-go@v7
            with:
              go-version-file: go.mod
          - uses: golangci/golangci-lint-action@v9
            with:
              version: v2.15
              install-only: true
          - run: make check
    ```
  - `.github/dependabot.yml`: a `gomod` entry (`directory: /`, prefix `chore(deps)`) with the three language groups, next to `github-actions`.
  - Released: `release-please-config.json` with `"release-type": "go"` (tags `v*`, as Go module versions need).

## CI hygiene
Every workflow in `.github/workflows/`, the standard's own included, and every `action.yml` in the repo (local actions). `scripts/workflow.py` checks each file (see [Audit](#audit)). The kind of a file comes from its path (`action.yml` / `action.yaml` is action metadata, checked with `--action`), never from its content; a file with both `jobs:` and `runs:` fails `wf_parsed`. It parses the file with a real YAML 1.2 parser, `ruamel.yaml` (version pinned in the script, hashes in `scripts/workflow.py.lock`, run through `uv run --script --locked`), and reads every rule from the parsed tree. It fails `wf_parsed`, and so fails closed, on:
  - a YAML error;
  - a duplicate key, anywhere in the file;
  - a merge key (`<<`) or an explicit tag (`!!bool`, `!x`);
  - more or fewer than one document;
  - a structure it does not expect where a rule reads (a step that is not a mapping, a trigger that is not a string, ...);
  - a byte-level tripwire: a CR left after CRLF is folded, NEL, LS or PS, or input that is not UTF-8. YAML parsers disagree on those line breaks.

  Anchors and aliases are resolved by the parser. A leading BOM is dropped, as YAML does. A crash of the checker, or of `uv`, or a missing `scripts/workflow.py.lock` (`--locked` would run unhashed) stops the audit with exit 2 (the audit broke), never a pass. Each rule has a fixture in `tests/workflows/`; `scripts/test-sync.sh` covers the audit's own decisions.
- **Timeouts**: every job sets `timeout-minutes` to a plain positive decimal integer (not `1_0`, `0b101`, `010`) or to one `${{ }}` expression that is not a constant (a job that calls a reusable workflow cannot; the called workflow's jobs set it). A job that runs out fails, so a required check turns red, never skipped.
- **Permissions**: top-level `permissions:` with the least the workflow needs (`contents: read` unless it needs more), widened per job where one job needs more; never `write-all`, at the top level or on a job; an empty `permissions:` fails too.
- **Concurrency**: a workflow that runs on `pull_request` sets `concurrency:`, one group per event, and cancels in progress only for `pull_request` (a superseded run on the same PR; the run for the new head still reports every check). `merge_group` runs and default-branch pushes are never cancelled. A group with `cancel-in-progress: false` still replaces a pending run, so those runs get a group of their own (`github.run_id`):
  ```yaml
  concurrency:
    # one group per pull request, superseded runs cancelled; every other run gets its own group, never cancelled
    group: ${{ github.workflow }}-${{ github.event_name }}-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
    cancel-in-progress: ${{ github.event_name == 'pull_request' }}
  ```
  In a workflow that also runs on `push`, `merge_group` or `workflow_call` (a reusable workflow runs in its caller's context, which may be a push):
  - every concurrency group (top level or job) must use `github.run_id` inside a `${{ }}` expression;
  - a literal true `cancel-in-progress` (`true`, `"true"`, `yes`, `${{ true }}`) fails the audit.

  Known limits:
  - That the group gives each such run its own value is not proven, only that the expression uses `github.run_id`: copy the block above.
  - Only push, merge_group and reusable (workflow_call) runs are protected. A workflow on `pull_request` and `schedule` (or `workflow_dispatch`) with a shared group and `cancel-in-progress: true` lets a PR run cancel a scheduled run. The block above avoids that; the audit does not check it.
- **Merge queue**: where a repo has one, every workflow that reports a required check also triggers on `merge_group`. User-owned repos have none (see [Ruleset](#ruleset-standardruleset-mainjson)); `pr-title.yml` carries the trigger already.
- **Pinned actions**: every `uses:` of a workflow step, a reusable-workflow job or a composite action step names a full commit SHA with its version tag as a comment on the same line (`actions/checkout@<sha> # v7.0.1`).
  - A remote ref with a `.` or `..` path segment fails (the runner joins that path onto the pinned checkout without a check).
  - A `docker://` ref, in a step or as an action's `runs.image`, and a job's `container` and `services` images need an image digest (`alpine@sha256:<64 hex>`).
  - A local `./` ref must point at a regular file in the repo: an `action.yml` / `action.yaml` in that directory (the repo root for `./`), or a workflow file. That `action.yml` is checked by the same rules. A symlink never counts, and a `./` ref that climbs out of the repo (`..`) fails. The audit resolves each tag upstream (`git/ref/tags/<tag>`, annotated tags dereferenced) and fails a SHA that is not the commit the tag points to, so a made-up, forked or mislabelled SHA does not pass. Dependabot bumps the SHA and the comment.
  - Known limits:
    - An older release pinned correctly passes; Dependabot (`github-actions`, plus security updates) moves it forward.
    - Verification trusts where the tag points today: if upstream moves a tag (a retag or a compromise), its new commit passes, and the old, correct pin fails, which is drift, not a pass.
    - A major-tag comment (`# v7`) passes only until the next `v7.x` moves that tag.
  - Only an HTTP 404 counts as "tag not found". Any other failure stops the audit with exit 2 (the audit broke) and prints the cause, so it never reaches the drift issue: an API error (token, 403, rate limit, 5xx) on a tag, a file, the repo or its tree, a truncated repo tree, a crash of the checker, or any other failed command. The settings probes that answer 404 for "disabled" (Dependabot alerts and security updates, private vulnerability reporting) read any failure as disabled, which is drift.
  - The standard workflows here are pinned too. A repo's copy matches the standard when it is byte-equal, or equal but for refs that each pass that check, so a Dependabot bump in the repo is not drift; an unpinned or unverified ref is drift.
  - `sync.sh apply workflows` leaves such a copy alone, replaces any other (an unpinned one included), and when it replaces a copy it keeps the repo's verified pins that are newer than the standard's: it never downgrades a pin.
  - Dependabot here bumps `.github/workflows/` only, not `standard/workflows/`; `make test` fails until the same bump is copied there (`cp .github/workflows/{pr-title,label-guard,todo-issues}.yml standard/workflows/`), so the two stay equal.
- **Narrow triggers**: a workflow that acts on the default branch only triggers on it (`branches:`), not on every push with a job-level skip.

These rules never cost a check. On every pull request the required checks always run, whatever the paths, never behind a job-level skip: `check` (with the gitleaks secret scan) and `Validate PR title`; so does every workflow lint (e.g. actionlint) or dependency review a repo adds. No rule here removes a required check, makes one skippable or loosens a ruleset or a permission.

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
Each repo has `AGENTS.md` and `docs/`; this standard is linked, not copied. No `CLAUDE.md`: Claude Code reads `AGENTS.md` wherever no `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md` sits in that directory or above (its default `claude-md-or-agents-md`, [docs](https://code.claude.com/docs/en/memory)), and the other harnesses read `AGENTS.md` natively. A monorepo component's own `AGENTS.md` loads the same way, when Claude reads a file there.

## Agent config
Shared agent config is committed; personal and machine state is not. The repo's own `.gitignore` carries the ignore lines of `standard/gitignore-agents`, since a global excludes file reaches neither other clones nor CI. `giocaizzi/template` ships them; the audit checks them (`agent_ignore`) and `sync.sh apply gitignore` opens a PR adding the missing ones.

- **Track:** `AGENTS.md`; `.claude/` (`settings.json`, `agents`, `commands`, `skills`, `rules`, `output-styles`, `workflows`, `agent-memory`); `.mcp.json`; `.worktreeinclude`; `.github/` (`copilot-instructions.md`, `instructions`, `agents`, `skills`, `prompts`, `hooks`, `mcp.json`, `copilot/settings.json`); `.vscode/settings.json`, `.vscode/mcp.json`; `.codex/`; `.agents/skills`, `skills-lock.json`; `opencode.json(c)`, `.opencode/`; `.pi/` (`settings.json`, `mcp.json`, `extensions`, `skills`, `prompts`, `themes`).
- **Ignore:** every line of `standard/gitignore-agents` (local settings, Claude worktrees and local agent memory, `CLAUDE.local.md`, Copilot CLI local settings, opencode and pi install dirs).

Worktrees: Claude Code creates them inside the repo (`.claude/worktrees/`, hence the entry); Copilot CLI, Codex and opencode create them outside it. opencode also writes `.opencode/.gitignore` for its own dependencies. Sources: [Claude Code](https://code.claude.com/docs/en/claude-directory), [Copilot CLI](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference), [VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-instructions), [Codex](https://learn.chatgpt.com/docs/agent-configuration/agents-md), [opencode](https://opencode.ai/docs/config), [pi](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/configuration.md).

## Repo types (topics)
Each repo carries its metadata as GitHub topics, so no list of repos lives here: exactly one `std-<type>` (`std-python`, `std-typescript`, `std-go`, `std-infra`, `std-config`, `std-docs`), plus the flags `std-released` (ships versioned releases), `std-pypi` (published on PyPI) and `std-deploys` (has publish/deploy jobs), and `std-exception-<check>` for a documented [exception](#exceptions) (check id with `-` for `_`, e.g. `std-exception-agent-ignore`). The type decides which typed rules apply; `std-pypi` and `std-deploys` switch on the checks in [Environments and publishing](#environments-and-publishing). `make onboard` sets them; change them with `gh repo edit giocaizzi/<repo> --add-topic|--remove-topic`. `scripts/meta.jq` parses them.

## Audit
`scripts/sync.sh audit` reports three kinds of checks; standard and typed failures are drift (exit 1), extras never are.
- **Standard** (every repo): exactly one `std-<type>` topic (`repo_type`); `ci.yml` job `check` with `needs` + `if: always()`; Makefile `check` target; gitleaks in `ci.yml`; standard `pr-title`, `label-guard` and `todo-issues` workflows (byte-equal, or equal but for verified `uses:` refs; the comparison blanks refs with `scripts/workflow.awk -v mode=norm`) and a `main` or `master` default branch (`todo_issues_branch`); the [CI hygiene](#ci-hygiene) rules on every workflow and `action.yml` (`wf_parsed`, `wf_permissions`, `wf_timeout`, `wf_concurrency`, `wf_pinned`, the last with each pin resolved upstream and each `./` ref found in the repo); Dependabot with grouped updates and a Conventional Commit `commit-message.prefix` on every entry; `AGENTS.md` and no tracked `CLAUDE.md` (`no_claude_md`; `sync.sh apply claude-md` opens a PR deleting the ones that are symlinks to `AGENTS.md`); the agent-config lines in `.gitignore` (`agent_ignore`); squash-only, delete-branch; no poetry; labels (standard plus the repo's `.github/labels.yaml`, no other, no extra redefining a standard one); `SECURITY.md` and issue templates (own or inherited); on public repos also auto-merge, `main` ruleset, secret scanning, private vulnerability reporting and `LICENSE`.
- **Typed** (when applicable): tests (python, typescript, go); `uv.lock` + ruff + mypy + pytest (python); `go.mod` + `go vet` + `golangci-lint run` + `go test` with `-race` (any flag position, or `GOFLAGS`) + `govulncheck` in `ci.yml` or the Makefile (`go_toolchain`, go); hadolint in `ci.yml` or Makefile (any Dockerfile); a validate step (infra); `release-please-config.json` (released), plus `uv.lock` in its `extra-files` when the repo has one (`uv_lock_release`: release-please does not bump the version `uv.lock` records; select each `[[package]]` with `$.package[?(@.name.value=='<name>')].version`); `informational: true` (when `codecov.yml` exists); `environments` and `pypi_publish` (public repos only).
  - `environments` (`deploys: true` or `pypi: true`): every job in `.github/workflows/*.yml` with a publish/deploy step declares `environment:`. A step counts as publish/deploy when the job contains `gh-action-pypi-publish`, `uv publish`, `docker push`, `deploy-pages`, `cosign sign`, `wrangler deploy`, a `/webhooks/` call, `scp`/`rsync`/`ssh`, or `docker/build-push-action` with `push: true`. Repository secrets named like `PYPI|DEPLOY|PORTAINER|WEBHOOK|SSH|REGISTRY|DOCKER` also fail it (names only).
  - `pypi_publish` (`pypi: true`): `release-please-config.json` plus a workflow that publishes with `pypa/gh-action-pypi-publish` or `uv publish`, `id-token: write`, no token, `environment: pypi`, triggered by `release:` or a release-please output.
- **Extras** (presence only): pre-commit, CODEOWNERS, changelog, Dockerfile, live docs site (GitHub Pages or a homepage URL), plus tests, Terraform and `LICENSE` where not required.

`--json` emits one object per repo (checks, extras, exemptions, scores). `--visibility public|private|all` (default `all`) limits the scope. This repo is public, so its weekly audit runs `--visibility public` and its `audit` artifact and `drift` issue cover public repos only; private repos are audited locally (the owner's dashboard runs `sync.sh audit --json --visibility private` with the owner's `gh` login), so nothing about them is stored on GitHub, and no private repo is named here.

## Exceptions
- `giocaizzi` (profile bot) pushes `main` directly: no `main` ruleset (see [Bots](#bots)).
- Private repos on the free plan: no ruleset, auto-merge or secret scanning (see below); the audit lists those checks under `exempt`.

## Private repos on the free plan
Rulesets, branch protection, auto-merge and secret scanning are unavailable (GitHub returns 403/422). Private repos keep everything else: squash-only, delete-on-merge, labels, a `check` CI job with gitleaks, and the PR-only convention enforced by `AGENTS.md`. Moving to GitHub Pro or making a repo public lifts this; then rerun `sync.sh apply`.
