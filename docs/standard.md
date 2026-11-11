# GitHub standard

Applies to all non-fork, non-archived repositories of `giocaizzi`. Reference implementation: `giocaizzi/greenhouse`. Machine-readable parts live in `standard/`. `scripts/sync.sh audit` checks every rule below (see [Audit](#audit)).

## New repos
Start from `giocaizzi/template` and run `make onboard REPO=<name> TYPE=<type> [FLAGS=...]`, which sets the repo's [topics](#repo-types-topics) and applies the standard (runbook: [runbook-rollout.md](runbook-rollout.md)). Nothing in GitHub applies this standard automatically on a personal account; the weekly audit flags any repo that skipped it.

## Pull requests
- `main` changes only through a PR that passed CI; no bypass actors, no force-push, no deletion.
- Squash merge only. The squash commit is built from the PR, never from branch commits: title = PR title (`squash_merge_commit_title: PR_TITLE`), body = PR description (`squash_merge_commit_message: PR_BODY`). Branch commit messages are history only.
- PR title is a Conventional Commit header, `type(scope): lowercase description`; it is the commit on `main` and drives release-please. Required check `Validate PR title` (`standard/workflows/pr-title.yml`) enforces it in CI; the `guard` plugin of `giocaizzi/harness` enforces it before `gh pr create` / `git commit` run.
  - It runs on `opened`, `edited`, `synchronize`, `reopened` and `ready_for_review`, and on `merge_group`. The title is read from an env var, never interpolated into the script.
  - How a required check reads runs: a job skipped by a job-level `if` reports success and does not block a merge ([GitHub docs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-jobs-with-conditions)); only a workflow skipped by a trigger filter (`paths`, `branches`, a commit message) leaves its check pending ([GitHub docs](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks)). A commit can carry several runs of one check (one per workflow run, all listed in the PR's checks), and GitHub does not document which one a required check reads; treat a later skip as able to replace an earlier failure and turn the check green.
  - So the job skips only a draft's `edited` event that leaves the title alone (no `changes.title`, e.g. a body edit): no runner starts, so no minute is billed. The job's `name` is an expression that gives the skipped path another name (GitHub lists a skipped job under the unevaluated expression text; evaluated, it reads `Skip PR title (draft edit)`), so the skipped run never reports `Validate PR title` and cannot stand in for a failed run, even in the moment after `ready_for_review` and before its new run starts; a draft cannot merge, and `ready_for_review` validates the title again. On a ready PR every edit still runs. A green no-op step would not help: the job still starts and is billed, rounded up to a whole minute ([GitHub docs](https://docs.github.com/en/billing/reference/actions-runner-pricing)), and it would report `Validate PR title` without validating.
  - Known gap: a `merge_group` run validates nothing (the step runs on `pull_request` only), so a queue trusts the PR run. No user-owned repo has a queue. The recommended fix for a repo with one: in the `merge_group` run, read the queued PR's number from `github.event.merge_group.head_ref` (`refs/heads/gh-readonly-queue/<base>/pr-<n>-<sha>`), fetch its title with `gh pr view <n> --json title` (`pull-requests: read`) and validate it in the same env-var script.
- PR description follows `.github/PULL_REQUEST_TEMPLATE.md` (What / Why / Verification), then footers as plain trailing lines: `BREAKING CHANGE:`, `Refs:`, attribution.
- Auto-merge on; head branch deleted on merge (`delete_branch_on_merge`, audited). Stacked PRs with `gh stack` for layered work.
- Agents follow the branch lifecycle in the `github-workflow` skill of `giocaizzi/harness`: one PR per coherent deliverable, every commit pushed after a secret scan, a draft PR from the first push, worker branches never pushed, branches of PRs closed unmerged deleted after 7 idle days, and unpushed branches archived under `refs/archive/` (expiring after 90 days) before their local copy is removed.
- Merge `main` into a PR only when the PR cannot land without it: a merge conflict, or, where the ruleset requires an up-to-date branch and there is no merge queue (every user-owned repo, see [Ruleset](#ruleset-standardruleset-mainjson)), once, when the PR is otherwise ready (review verdict on its head, CI green), right before it merges. Being behind `main` is no reason on its own: a merge queue tests each entry on the latest `main` plus the entries ahead of it ([GitHub docs](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue#how-merge-queues-work)), and every new head restarts CI and voids a review verdict given on the old one.
- Drafts are not gated by CI: `ci.yml` skips every job on a draft and runs the PR's usual run (the light tier in a [tiered](#ci-tiers) repo) when the PR is marked ready (see Drafts under [CI hygiene](#ci-hygiene)). Prove the gate locally with `make prepush`, then mark the PR ready once (`gh pr ready`). Each later round is a push to the ready PR, never a switch back to draft and ready again: each `ready_for_review` starts another run. A draft that needs CI runs it on demand: `gh workflow run ci.yml --ref <branch>` (in a tiered repo that is the full tier, the expensive path).
- Review threads must be resolved; approvals 0 while solo.

## Attribution
Who wrote a change must survive the squash, so attribution lives in the PR description:
- **AI-authored or co-authored work**: one `Co-Authored-By:` trailer per model that actually wrote code in the PR, naming that model exactly as the harness reports it (e.g. `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`), never a guessed or configured name. Subagents on another model add their own trailer. The description ends with the harness's generated-by line (Claude Code: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`; Copilot CLI: its own co-author trailer).
- **Bots** (Dependabot, release-please) attribute themselves; leave them as they are.
- **Human-only work**: no trailer.
- Branch commits carry the same trailer, but only the PR description reaches `main`.

## Ruleset (`standard/ruleset-main.json`)
Default-branch rules: PR required (squash), up-to-date branch, required status checks `check` and `Validate PR title` (a minimum: a repo may require more, e.g. a leak check; the audit and `sync.sh apply ruleset` keep them), no deletion or force-push. `check` is one aggregate CI job (`needs: [...]`, an `if` starting with `always()`, see Drafts under [CI hygiene](#ci-hygiene)) so job renames never touch the ruleset. No merge queue on user-owned repos (not offered); strict up-to-date checks plus auto-merge replace it.

## Repo settings (`standard/repo-settings.json`)
Squash only, auto-merge, delete-branch-on-merge, secret scanning and push protection, private vulnerability reporting (the last four on public repos only). Dependabot alerts and Dependabot security updates on every repo (free on private repos too; `sync.sh apply settings` enables them through their own endpoints, not `repo-settings.json`). Dependabot version updates: [Dependabot updates](#dependabot-updates).

## Dependabot updates
Every repo has `.github/dependabot.yml`: `github-actions` plus each package ecosystem it uses. Every update PR pays a full PR run and a push run after it merges, so updates are batched twice, in time (one weekly run, a cap on open update PRs) and by grouping (one PR per group, never one per dependency): a week's bumps cost about one or two PRs' CI per ecosystem.

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    open-pull-requests-limit: 1
    commit-message:
      prefix: "ci(deps)"
    groups:
      github-actions:
        patterns: ["*"]
  - package-ecosystem: uv # or pip, npm, gomod, ...
    directory: /
    schedule:
      interval: weekly
    open-pull-requests-limit: 2
    commit-message:
      prefix: "chore(deps)"
    groups:
      minor-patch:
        update-types: [minor, patch]
      major:
        update-types: [major]
      security:
        applies-to: security-updates
        patterns: ["*"]
```

- **Schedule**: `schedule.interval: weekly` on every entry (Monday by default, so every entry runs the same day).
- **Cap**: `open-pull-requests-limit` on every entry, set to its number of version-update groups: `1` for `github-actions` and `docker` (one group), `2` for a language ecosystem (`minor-patch` and `major`). The default is 5. Never `0`: that turns the entry's version updates off.
- **Groups**, on every entry: `github-actions` and `docker` have one group, `patterns: ["*"]`. A language ecosystem (uv, pip, npm, gomod, ...) has `minor-patch` (`update-types: [minor, patch]`: every minor and patch bump in one PR), `major` (`update-types: [major]`: breaking bumps in a PR of their own, reviewed apart from the routine batch) and `security`. A dependency that matches no group gets a PR of its own, which is what the groups exist to prevent.
- **Security updates are never held back**: they come from Dependabot security updates (a repo setting, see [Repo settings](#repo-settings-standardrepo-settingsjson)), which Dependabot raises as advisories appear, outside the schedule, without the version-update cooldown and outside `open-pull-requests-limit` (they have their own fixed cap of 10 open PRs). The `security` group (`applies-to: security-updates`) only puts the fixes for one ecosystem that are open at the same time into one PR; it never delays one. Groups without `applies-to` cover version updates only. Nothing in this shape turns security updates off (an `ignore` or `allow` rule would filter them too, so the shape has none).
- **Commit messages**: every entry sets `commit-message.prefix` so Dependabot PR titles pass the `Validate PR title` check: `ci(deps)` for `github-actions`, `chore(deps)` for every other ecosystem (no `include: scope`). Dependabot lowercases `bump` after a lowercase prefix unless the latest Dependabot commit on the default branch starts `type: Bump`; then it copies that capital, and the title of such a PR is edited to lowercase before merging.
- **Labels**: no `labels:` key, which would replace Dependabot's default labels: `dependencies` plus the ecosystem's own (`github_actions`, `python:uv`, `javascript`, ...), all in `standard/labels.yaml`. An ecosystem whose default label is not there gets it added to `standard/labels.yaml` first; otherwise the `label-guard` workflow deletes it.
- **Audited**: `dependabot` (the file exists), `dependabot_grouped` (every entry has a version-update group: an entry with no `groups`, an empty one, or only `applies-to: security-updates` groups is drift; the `security` group is neither required nor counted) and `dependabot_prefix`. The schedule, the cap and the labels are documented, not audited. The audit reads block-style YAML with `package-ecosystem` as each entry's first key; any other layout reads as drift.

## Labels (`standard/labels.yaml`)
Type (bug, enhancement, documentation, question, wontfix, invalid, duplicate), priority P1–P3, `parity`, `keep`, `security` and `stale` (see [Stale PRs and issues](#stale-prs-and-issues)), and the automation labels Dependabot, release-please and the `todo-issues` workflow create. A repo may declare its own extra labels in `.github/labels.yaml` (same format, optional; this repo's holds `drift`); an extra that reuses a standard name is ignored and fails the audit. No other label may exist: `sync.sh apply labels` creates the standard and the repo's extras and deletes the rest, and the `label-guard` workflow (`standard/workflows/label-guard.yml`) deletes any other label as soon as it is created or renamed. A label every repo needs goes in `standard/labels.yaml` here; one only a repo needs goes in that repo's `.github/labels.yaml`. GitHub cannot block label creation natively.

## TODO tracking
Every repo runs `standard/workflows/todo-issues.yml` (`alstr/todo-to-issue-action`): a push to the default branch that adds a `TODO` comment opens an issue labelled `todo`, and removing the comment closes it. It triggers on pushes to `main` or `master` only (the default branch names in use; `on.push.branches` cannot read the default branch), plus manual dispatch, and its job-level `if` keeps it to the default branch, so pushes to other branches start no run. A default branch with another name fails the audit (`todo_issues_branch`). It reads the push diff only; to import the TODOs a repo already has, `sync.sh apply todos <repo>` runs it once by hand over the whole history (an issue with the same title, open or closed, is never duplicated).

## Stale PRs and issues
Every repo runs `standard/workflows/stale.yml` (`actions/stale`), daily and on manual dispatch.
- **Timings**: a PR is marked `stale` after 30 idle days and closed 14 days later; an issue after 90 idle days and 30 days later. Any activity (a comment, a push, a label change) removes `stale` and resets the clock (`remove-stale-when-updated`). Drafts age like other PRs.
- **Exempt**: items labelled `keep` or `security`; PRs labelled `autorelease: pending`, `autorelease: tagged` (release-please) or `dependencies` (Dependabot); issues with a milestone; pinned issues. `actions/stale` has no input for pinned issues, so the workflow's first step adds `keep` to each pinned issue (idempotent); if that query fails it logs a warning and the stale step still runs.
- **Branches**: `delete-branch` is `false`. The branch of a PR closed as stale is removed later by the agents' branch sweep, 7 idle days after the close (see [Pull requests](#pull-requests)).
- **Audit**: the `stale` check, like `pr-title`, `label-guard` and `todo-issues`; see [Audit](#audit).

## CI and releases
- One `ci.yml` per repo, plain (no reusable workflows). Python: `uv`, ruff, mypy, pytest; new projects start with ruff `select = ["ALL"]` and Google docstrings (`pydocstyle` `convention = "google"`). Every repo exposes `make help|lint|test|check|prepush` and CI runs `make check`. `make prepush` is the local gate: an agent runs it, and it must pass, before marking a PR ready. In a repo without [CI tiers](#ci-tiers) it is `check` itself (`prepush: check`); in a tiered repo it is the light tier plus the integration tests of the touched packages.
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
  - a merge key (`<<`), an explicit tag (`!!bool`, `!x`) or a directive (`%YAML 1.1` changes how `yes` and `on` resolve);
  - more or fewer than one document;
  - a structure it does not expect where a rule reads (a step that is not a mapping, a trigger that is not a string, ...);
  - a byte-level tripwire: a CR left after CRLF is folded, NEL, LS or PS, or input that is not UTF-8. YAML parsers disagree on those line breaks.

  Anchors and aliases are resolved by the parser. A leading BOM is dropped, as YAML does. A crash of the checker, or of `uv`, or a missing `scripts/workflow.py.lock` (`--locked` would run unhashed) stops the audit with exit 2 (the audit broke), never a pass. Each rule has a fixture in `tests/workflows/`; `scripts/test-sync.sh` covers the audit's own decisions.
- **Timeouts**: every job sets `timeout-minutes` to a plain positive decimal integer (not `1_0`, `0b101`, `010`) or to one `${{ }}` expression that reads a context (`inputs`, `vars`, `matrix`, ...; a constant such as `${{ 0x0 }}` or `${{ '5' }}` fails) (a job that calls a reusable workflow cannot; the called workflow's jobs set it). A job that runs out fails, so a required check turns red, never skipped.
- **Permissions**: top-level `permissions:` with the least the workflow needs (`contents: read` unless it needs more), widened per job where one job needs more; never `write-all`, at the top level or on a job; an empty `permissions:` fails too.
- **Concurrency**: a workflow that runs on `pull_request` sets `concurrency:`, one group per event, and cancels in progress only for `pull_request` (a superseded run on the same PR; the run for the new head still reports every check). `merge_group` runs and default-branch pushes are never cancelled. A group with `cancel-in-progress: false` still replaces a pending run, so those runs get a group of their own (`github.run_id`):
  ```yaml
  concurrency:
    # one group per pull request, superseded runs cancelled; every other run gets its own group, never cancelled
    group: ${{ github.workflow }}-${{ github.event_name }}-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
    cancel-in-progress: ${{ github.event_name == 'pull_request' }}
  ```
  In a workflow that also runs on `push`, `merge_group` or `workflow_call` (a reusable workflow runs in its caller's context, which may be a push):
  - every concurrency group (top level or job) must have an expression whose value is `github.run_id`: `${{ github.run_id }}` itself, or the documented `${{ github.event_name == 'pull_request' && <context> || github.run_id }}`. `${{ github.ref || github.run_id }}` (the ref is always set, so push runs share it) and `${{ 'github.run_id' }}` (a string) fail;
  - a literal true `cancel-in-progress` (`true`, `"true"`, `yes`, `${{ true }}`) fails the audit.

  Known limits:
  - Only those two expression shapes are recognised; any other way of reaching `github.run_id` fails, so copy the block above.
  - Only push, merge_group and reusable (workflow_call) runs are protected. A workflow on `pull_request` and `schedule` (or `workflow_dispatch`) with a shared group and `cancel-in-progress: true` lets a PR run cancel a scheduled run. The block above avoids that; the audit does not check it.
- **Drafts**: `ci.yml` triggers on `pull_request` with `types: [opened, synchronize, reopened, ready_for_review]` (the default types leave out `ready_for_review`) and on `workflow_dispatch` (an on-demand run, write access needed). Every job without `needs`, and every job whose `if` uses a status function (`always()`, `!cancelled()`, `failure()`), adds `!github.event.pull_request.draft` to its `if` (true on every other event, where `pull_request` is unset); the other jobs that need them are skipped with them. `check` runs on `always() && !github.event.pull_request.draft` and takes the job-name trick of `pr-title.yml` (see [Pull requests](#pull-requests)), so a draft's skipped run never reports `check` and cannot stand in for the run that `ready_for_review` starts:
  ```yaml
  check:
    name: ${{ github.event.pull_request.draft && 'Skip CI (draft)' || 'check' }}
    needs: [secrets, changes]
    if: ${{ always() && !github.event.pull_request.draft }}
  ```
  Any other required check a repo adds (see [Ruleset](#ruleset-standardruleset-mainjson)) sits under `check`'s `needs` or takes the same name trick: a skipped job reports success under its name, so a bare draft condition would turn it green without validating anything. A re-run of a run from the draft period reuses its payload (`draft: true`) and skips again. The required checks and the ruleset do not change: a draft cannot merge, and `ready_for_review` runs every check on the head that merges. Documented, not audited (like [CI tiers](#ci-tiers)).
- **Merge queue**: where a repo has one, every workflow that reports a required check also triggers on `merge_group`. User-owned repos have none (see [Ruleset](#ruleset-standardruleset-mainjson)); `pr-title.yml` carries the trigger already.
- **Pinned actions**: every `uses:` of a workflow step, a reusable-workflow job or a composite action step names a full commit SHA with its version tag as a comment on the same line (`actions/checkout@<sha> # v7.0.1`).
  - A remote ref with a `.` or `..` path segment, or any `\` (a path separator on Windows runners), fails: the runner joins that path onto the pinned checkout without a check.
  - A `docker://` ref, in a step or as an action's `runs.image`, and a job's `container` and `services` images need an image digest (`alpine@sha256:<64 hex>`).
  - A local `./` ref must point at a regular file in the repo: an `action.yml` / `action.yaml` in that directory (the repo root for `./`), or a workflow file. That `action.yml` is checked by the same rules. A symlink never counts, and a `./` ref that climbs out of the repo (`..`) fails. The audit resolves each tag upstream (`git/ref/tags/<tag>`, annotated tags dereferenced) and fails a SHA that is not the commit the tag points to, so a made-up, forked or mislabelled SHA does not pass. Dependabot bumps the SHA and the comment.
  - Known limits:
    - An older release pinned correctly passes; Dependabot (`github-actions`, plus security updates) moves it forward.
    - Verification trusts where the tag points today: if upstream moves a tag (a retag or a compromise), its new commit passes, and the old, correct pin fails, which is drift, not a pass.
    - A major-tag comment (`# v7`) passes only until the next `v7.x` moves that tag.
  - Only an HTTP 404 counts as "tag not found". Any other failure stops the audit with exit 2 (the audit broke) and prints the cause, so it never reaches the drift issue: an API error (token, 403, rate limit, 5xx) on a tag, a file, the repo, its tree or its secret list; a truncated repo tree; a path in the tree with a control character (the tree is read as lines); a crash of the checker; or any other failed command. File names are only ever data: they are percent-encoded in API URLs and reach awk through `ENVIRON`, so `&`, `\`, `|`, `?` or `#` in a name change nothing. The settings probes that answer 404 for "disabled" (Dependabot alerts and security updates, private vulnerability reporting) read any failure as disabled, which is drift.
  - The standard workflows here are pinned too. A repo's copy matches the standard when it is byte-equal, or equal but for refs that each pass that check, so a Dependabot bump in the repo is not drift; an unpinned or unverified ref is drift.
  - `sync.sh apply workflows` leaves such a copy alone, replaces any other (an unpinned one included), and when it replaces a copy it keeps the repo's verified pins that are newer than the standard's: it never downgrades a pin.
  - Dependabot here bumps `.github/workflows/` only, not `standard/workflows/`; `make test` fails until the same bump is copied there (`cp .github/workflows/{pr-title,label-guard,todo-issues,stale}.yml standard/workflows/`), so the two stay equal.
- **Narrow triggers**: a workflow that acts on the default branch only triggers on it (`branches:`), not on every push with a job-level skip.

These rules never cost a check. On every ready pull request (a draft runs no CI, see Drafts above) the required checks always run, whatever the paths: `check` (with the gitleaks secret scan) and `Validate PR title` (which skips only a draft's edit that leaves the title alone, see [Pull requests](#pull-requests)); so does every workflow lint (e.g. actionlint) or dependency review a repo adds. In a repo with a merge queue, [CI tiers](#ci-tiers) move only full-tier jobs off the PR run; `check` still reports on every run but a draft's. No rule here removes a required check, makes one skippable or loosens a ruleset or a permission.

## CI tiers
Only in a repo whose default branch has a merge queue that every change must pass (the ruleset requires it, with an empty bypass list). A repo without one (every user-owned repo, see [Ruleset](#ruleset-standardruleset-mainjson)) has no tiers: the PR run is the gate and runs everything.

- **Light tier, every PR push**: the secret scan (gitleaks), workflow lint (actionlint, where the repo runs it), `Validate PR title`, build, vet and lint, and the unit tests of the touched packages (or the repo's cheapest correct test subset; touched packages come from a `changes` job, as in the harness [CI for a gate checklist](https://github.com/giocaizzi/harness/blob/main/plugins/dev-tools/skills/github-workflow/SKILL.md#ci-for-a-gate-checklist)). `Validate PR title` reports on its own; everything else rolls up into the required aggregate `check`.
- **Full tier, `merge_group` only** (and an opt-in dispatch and the rollback variable, below): slow or wide suites (integration tests, chart tests, end-to-end scenarios, cross-OS legs, image and release builds, the coverage floor). The `merge_group` run tests the base plus the queued entries, the tree that lands.
- **How**: each full-tier job carries a job-level `if: github.event_name == 'merge_group' || github.event_name == 'workflow_dispatch'` (plus the rollback condition below), never a workflow-level `paths` / `paths-ignore` filter or a workflow of its own, so `check` always reports on a ready PR, `merge_group`, push and dispatch; `ci.yml` also triggers on `merge_group` and `workflow_dispatch`. `check` accepts `skipped` only for the jobs of the tier that event leaves out (an explicit per-job, per-event allowlist, never "skipped is fine") and, for a job a `changes` job gates, a skip only when `changes` said it was not needed (that needs its own branch in the step, not shown: the snippet fails such a skip closed); it fails on any other skip, failure or cancellation. Required checks and the ruleset do not change: `check` and `Validate PR title` report on both `pull_request` and `merge_group`.
  ```yaml
  check:
    name: ${{ github.event.pull_request.draft && 'Skip CI (draft)' || 'check' }}
    needs: [secrets, lint, unit, integration, e2e]
    if: ${{ always() && !github.event.pull_request.draft }}
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Fail unless every needed job passed, or was skipped by its tier
        env:
          EVENT: ${{ github.event_name }}
          RESULTS: ${{ toJSON(needs) }}
          FULL_TIER: integration e2e # skipped on pull_request and push
        run: |
          jq -e --arg event "$EVENT" --arg full "$FULL_TIER" '($full | split(" ")) as $f
            | to_entries | all(.value.result == "success"
              or (.value.result == "skipped" and ($event == "pull_request" or $event == "push") and (.key | IN($f[]))))' <<<"$RESULTS"
  ```
- **Early full run**: only by explicit opt-in, a `workflow_dispatch` of `ci.yml` on the PR branch (`gh workflow run ci.yml --ref <branch>`, write access needed, so a fork PR cannot be promoted and waits for the queue); never automatically on `ready_for_review`, unless the rollback variable below is set.
- **Security** (unchanged by tiering, see the harness [CI for a gate checklist](https://github.com/giocaizzi/harness/blob/main/plugins/dev-tools/skills/github-workflow/SKILL.md#ci-for-a-gate-checklist)): PR code never gets secrets or a write token; no `pull_request_target` for tier logic; no `actions: write` to cancel runs for a fast fail; fork and bot PRs take the same path as any other.
- **Local gate**: `make prepush` (see [CI and releases](#ci-and-releases)) is the light tier plus the integration tests of the touched packages.
- **Rollback to a full PR run**: the repository variable `CI_FULL_TIER_ON_PR` set to `true` runs the full tier on ready PR runs too, with no workflow change; deleting it returns to tiers (runbook: [Tier a repo's CI](runbook-rollout.md#tier-a-repos-ci-repos-with-a-merge-queue-only)). Each full-tier job's `if` reads it: `github.event_name == 'merge_group' || github.event_name == 'workflow_dispatch' || (github.event_name == 'pull_request' && !github.event.pull_request.draft && vars.CI_FULL_TIER_ON_PR == 'true')`. With the variable set those jobs run and `check` needs them to pass; the allowlist does not change.
- Why tiers pay off, and how to measure minutes per workflow and event: the harness [ci-cost.md](https://github.com/giocaizzi/harness/blob/main/plugins/dev-tools/skills/repo-standard/references/ci-cost.md) and [github-workflow rule 1](https://github.com/giocaizzi/harness/blob/main/plugins/dev-tools/skills/github-workflow/SKILL.md#landing-a-change).

Documented, not audited (the audit cannot tell a repo's tiers from its jobs).

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
- **Standard** (every repo): exactly one `std-<type>` topic (`repo_type`); `ci.yml` job `check` with `needs` + `if: always()`; Makefile `check` target; gitleaks in `ci.yml`; standard `pr-title`, `label-guard`, `todo-issues` and `stale` workflows (byte-equal, or equal but for verified `uses:` refs; the comparison blanks refs with `scripts/workflow.awk -v mode=norm`) and a `main` or `master` default branch (`todo_issues_branch`); the [CI hygiene](#ci-hygiene) rules on every workflow and `action.yml` (`wf_parsed`, `wf_permissions`, `wf_timeout`, `wf_concurrency`, `wf_pinned`, the last with each pin resolved upstream and each `./` ref found in the repo); Dependabot with a version-update group and a Conventional Commit `commit-message.prefix` on every entry (`dependabot`, `dependabot_grouped`, `dependabot_prefix`; see [Dependabot updates](#dependabot-updates)); `AGENTS.md` and no tracked `CLAUDE.md` (`no_claude_md`; `sync.sh apply claude-md` opens a PR deleting the ones that are symlinks to `AGENTS.md`); the agent-config lines in `.gitignore` (`agent_ignore`); squash-only, delete-branch; no poetry; labels (standard plus the repo's `.github/labels.yaml`, no other, no extra redefining a standard one); `SECURITY.md` and issue templates (own or inherited); on public repos also auto-merge, `main` ruleset, secret scanning, private vulnerability reporting and `LICENSE`.
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
