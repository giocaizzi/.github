# Tooling inventory

An informational inventory of the tooling each repo uses (task runner, CI, Python, JavaScript and Go toolchains) and where it deviates from the house expectation. The standard itself is [standard.md](standard.md); this page only documents the inventory and its config, `standard/tooling.json`. Producer: `scripts/tooling.py` (uv script, `ruamel.yaml` pinned in its header and `scripts/tooling.py.lock`; after changing that pin run `uv lock --script scripts/tooling.py`). It reads only files the audit has already fetched and never uses the network.

## Cells

`tooling.py collect` prints one JSON object per repo, `{"<tool_id>": {"group", "value", "expected", "status", "severity"}}`:

- `group`: `common`, `python`, `js` or `go`. A language group applies when the repo has its marker file (below); otherwise every cell of the group is `n.a.` with an empty value.
- `value`: what the repo has, as text.
- `expected`: the expectation compared against (`null` when there is none, or the cell is ignored or its group does not apply).
- `status`: `same` (meets the expectation), `differs` (present, does not meet it), `absent` (the expected tool is missing), `n.a.` (group does not apply, check ignored, or no expectation: the value is still shown), `unknown` (a source file could not be read, value `cannot read`, or is malformed, value `unparseable`).
- `severity`: `info`, `warn` or `fail`, from the config. Only `fail` may affect the audit exit code and the drift issue; `info` and `warn` render only. Everything ships at `info`, so the inventory never turns a repo red until a severity is raised.

Version expectations compare numeric tuples; a range such as `>=3.12` or `^3.10` compares its lower bound, and a repo meets `>=3.14` when its lower bound is at least 3.14.

## Tool ids

| id | group | sources | value | default expectation |
|---|---|---|---|---|
| `make_targets` | common | `Makefile` | the targets of `help`, `lint`, `test`, `check` it defines | `help, lint, test, check` (all) |
| `pre_commit` | common | `.pre-commit-config.yaml` | `present` / `absent` | none |
| `gitleaks` | common | Makefile, workflows, pre-commit config | `present` / `absent` | `present` |
| `dependabot_groups` | common | `.github/dependabot.yml` | entries with a version-update group / all entries, e.g. `2/3` | `all` |
| `ci_check_job` | common | `ci.yml` | `present` (job `check`) / `absent` / `no ci.yml` | `present` |
| `docker_pins` | common | every `Dockerfile*` | `FROM` images pinned by `@sha256:` / all (stage aliases and `scratch` excluded), or `no Dockerfile` | `all` |
| `release_tooling` | common | `release-please-config.json`, `.release-please-manifest.json` | `release-please` / `none` | `release-please`, only for a released repo (`--released true`); otherwise none |
| `worktree_installs` | common | `Makefile` (comment lines skipped) | the [installs into the checkout](standard.md#ci-and-releases) it finds: `$(CURDIR)/bin`, `--bin-dir <path>` with a path inside the repo (relative, `$(CURDIR)`, `$(PWD)`), `./bin install` (an `install` line writing to `./bin`), else `none`; `no Makefile` is `n.a.` | `none` |
| `python_version` | python | `pyproject.toml` (`requires-python`, poetry `python`), `.python-version`, `setup-python` / `setup-uv` in workflows (matrices expanded) | `>=3.12; .python-version 3.13; ci 3.12,3.13` | `>=3.14`, on `requires-python`, else `.python-version` |
| `python_pm` | python | `uv.lock`, `poetry.lock`, `[tool.uv]`, `[tool.poetry]` | `uv` / `poetry` / `pip` | `uv` |
| `ruff` | python | `ruff.toml`, `.ruff.toml`, `[tool.ruff]` | `select=ALL, ignore=12 rules, line-length=120` | `select=ALL` |
| `ruff_format` | python | Makefile, workflows, pre-commit config | `present` / `absent` | `present` |
| `mypy` | python | `mypy.ini`, `[tool.mypy]`, `setup.cfg`; `mypy --strict` in CI commands | `strict`, `strict, 3 overrides`, `ignore_errors=2`, `default` (overrides that set `ignore_errors` are counted apart) | `strict` |
| `pytest` | python | `pytest.ini`, `[tool.pytest]`, `setup.cfg`, dependencies | the `pytest-*` plugins, e.g. `pytest-cov, pytest-xdist`, else `pytest` | none |
| `coverage_floor` | python | `[tool.coverage.report]`, `.coveragerc`, `setup.cfg`, `--cov-fail-under` | the floor, e.g. `90`, or `absent` | none |
| `node_version` | js | `engines.node`, `.nvmrc`, `.node-version`, `setup-node` in workflows | `engines >=26; .nvmrc 26; ci 26` | `>=26`, on `engines`, else the version file |
| `js_pm` | js | lock files, `packageManager` | `pnpm` / `npm` / `yarn` / `bun` / `none` | `pnpm` |
| `typescript` | js | `package.json` dependencies | the declared major | `7` (at least) |
| `eslint` | js | `eslint.config.*`, `.eslintrc*`, `package.json` | `flat v10`, `eslintrc v8`, `no config v10` | `10` (at least) |
| `prettier` | js | `.prettierrc*`, `prettier.config.*`, `package.json` | `present` / `absent` | `present` |
| `tsconfig_strict` | js | root `tsconfig*.json` (comments and trailing commas allowed; root-level `extends` followed) | `strict` or `not strict`, then the extra flags set (`noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, ...) | `strict` |
| `test_runner` | js | dependencies, `vitest` / `jest` config files | `vitest`, `jest`, `jest, vitest` or `none` | `vitest` |
| `go_version` | go | `go.mod` | `go 1.25.0; toolchain go1.25.3` | `>=1.26` |
| `golangci_lint` | go | `.golangci.{yml,yaml,toml,json}`, the `golangci-lint-action` version comment | `v2, default=standard, 5 enabled, action v9.0.0`, `v1, disable-all, 3 enabled` | `v2` (at least) |
| `golangci_baseline` | go | root `*golangci*baseline*` file | `present (<file>)` / `absent` | none |

Language groups apply on: `python` any of `pyproject.toml`, `setup.py`, a root `requirements*.txt`; `js` a root `package.json`; `go` a root `go.mod`.

`tooling.py wanted` (tree paths on stdin) prints the paths a collector reads, so the audit fetches nothing else: root config files, `Makefile`, workflows and Dockerfiles anywhere. Lock files, baselines and lint configs that are only checked for presence come from the tree listing and are not fetched.

## Config: `standard/tooling.json`

```json
{
  "checks": { "<tool_id>": { "severity": "info", "expected": "<override>" } },
  "repos": {
    "<repo>": {
      "checks": { "<tool_id>": { "severity": "warn", "expected": "<override>" } },
      "ignore": ["<tool_id>"]
    }
  },
  "ignore": { "repos": ["<repo>"], "checks": ["<tool_id>"] }
}
```

- `severity` is `info` (default), `warn` or `fail`; `expected` is a string in the value format of the table. Both are optional. Without an `expected`, the default of the table applies (and a check without one has none).
- Precedence, highest first: `repos.<repo>.checks`, `checks`, the built-in default.
- `ignore.checks` and `repos.<repo>.ignore` turn a check to `n.a.` (expected `null`, value still shown); `ignore.repos` makes `collect` print `{}` for the repo.
- An unknown key, an unknown tool id, a wrong type or a severity other than the three makes `collect` exit 2 with a message on stderr. A config error never passes silently.
- The shipped file lists every check at `info` with its default expectation and no repo entries; a test keeps it equal to the built-in defaults.

Example, `acme-app` stays on Python 3.12 for now and does not use mypy, and a missing `ci.yml` job `check` fails the audit for everyone:

```json
{
  "checks": { "ci_check_job": { "severity": "fail" } },
  "repos": { "acme-app": { "checks": { "python_version": { "expected": ">=3.12" } }, "ignore": ["mypy"] } }
}
```

## Changing an expectation

1. Change the standard in [standard.md](standard.md) first, then the expectation here.
2. Set `expected` under `checks` in `standard/tooling.json` (one repo: under `repos.<repo>.checks`). A new house default also changes the built-in default in `scripts/tooling.py` (`CHECKS`) and the table above; `make test` fails until the shipped config matches the defaults.
3. Raise a severity only once the repos meet the expectation: `fail` makes the deviation fail the audit.
4. Refresh fixtures with `UPDATE=1 scripts/test-tooling.sh` and review the diff of `tests/tooling/*/expected.json`.
