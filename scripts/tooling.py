# /// script
# requires-python = ">=3.12"
# dependencies = ["ruamel.yaml==0.19.1"]
# ///
"""Tooling inventory of one repository (docs/tooling.md): who uses what, and where it deviates from the house rules.

Informational: the audit (scripts/sync.sh) fetches the files `wanted` lists and runs `collect`, which prints one JSON
object of cells and exits 0; any other exit is a crash, which the audit treats as a broken run. Never touches the
network. Run it as `uv run --script --locked scripts/tooling.py ...` (ruamel.yaml is pinned above and in
tooling.py.lock).

    tooling.py wanted < paths
        the subset of the repo's tree paths (one per line on stdin) the collectors read
    tooling.py collect --repo R --type T --released true|false --config standard/tooling.json DIR
        DIR holds the fetched files at their repo paths, `.audit/paths` (all tree paths) and `.audit/unreadable`
        (paths that could not be read; may be missing or empty)

A cell is `{"group", "value", "expected", "status", "severity"}`; see docs/tooling.md for every tool id.
"""

from __future__ import annotations

import argparse
import configparser
import json
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, NamedTuple

from ruamel.yaml import YAML
from ruamel.yaml.error import YAMLError

if TYPE_CHECKING:
    from collections.abc import Callable, Sequence

    from ruamel.yaml.constructor import BaseConstructor
    from ruamel.yaml.nodes import ScalarNode

SEVERITIES = ("info", "warn", "fail")
TARGETS = ("help", "lint", "test", "check")
WORKFLOW = re.compile(r"\.github/workflows/[^/]+\.ya?ml", re.IGNORECASE)
CI_FILE = re.compile(r"\.github/workflows/ci\.ya?ml", re.IGNORECASE)
DOCKERFILE = re.compile(r"(?:.*/)?(?:Dockerfile[^/]*|[^/]*\.[Dd]ockerfile)")
REQUIREMENTS = re.compile(r"requirements[^/]*\.txt")
ESLINT_FLAT = re.compile(r"eslint\.config\.(?:js|mjs|cjs|ts|mts|cts)")
ESLINT_RC = re.compile(r"\.eslintrc(?:\.[a-z]+)?")
PRETTIER = re.compile(r"\.prettierrc(?:\..+)?|prettier\.config\.[a-z]+")
JS_TEST_CONFIG = re.compile(r"(vitest)\.(?:config|workspace)\..+|(jest)\.config\..+")
GOLANGCI = re.compile(r"\.golangci\.(?:ya?ml|toml|json)")
GOLANGCI_BASELINE = re.compile(r"\.?golangci[-_.]?baseline[^/]*")
TSCONFIG = re.compile(r"tsconfig[^/]*\.json")
# what `wanted` asks the audit to fetch: only files a collector reads (presence-only files come from the tree)
WANTED = re.compile(
    r"pyproject\.toml|\.python-version|ruff\.toml|\.ruff\.toml|mypy\.ini|setup\.cfg|pytest\.ini|\.coveragerc"
    r"|requirements[^/]*\.txt|package\.json|\.nvmrc|\.node-version|tsconfig[^/]*\.json|go\.mod"
    r"|\.golangci\.(?:ya?ml|toml|json)|Makefile|\.pre-commit-config\.ya?ml|\.github/dependabot\.ya?ml"
    r"|\.github/workflows/[^/]+\.[Yy][Aa]?[Mm][Ll]|(?:.*/)?(?:Dockerfile[^/]*|[^/]*\.[Dd]ockerfile)"
)
TS_FLAGS = (
    "noUncheckedIndexedAccess",
    "exactOptionalPropertyTypes",
    "noImplicitOverride",
    "noFallthroughCasesInSwitch",
    "noUnusedLocals",
    "noUnusedParameters",
    "noPropertyAccessFromIndexSignature",
)
SHORT_LIST = 5


class Unreadable(Exception):  # noqa: N818
    """A source file could not be fetched (listed in `.audit/unreadable`)."""


class Unparseable(Exception):  # noqa: N818
    """A source file is malformed."""


class Result(NamedTuple):
    """What a collector found: the value to show and its status against the expectation."""

    value: str
    status: str


@dataclass(frozen=True)
class Check:
    """One tool id: its group, its house expectation (None: none) and its collector."""

    tool_id: str
    group: str
    expected: str | None
    collect: Callable[[Ctx, str], Result]


def as_dict(x: object) -> dict[str, object]:
    """Return `x` as a str-keyed dict, empty when it is not a mapping."""
    return {str(k): v for k, v in x.items()} if isinstance(x, dict) else {}


def as_list(x: object) -> list[object]:
    """Return `x` as a list, empty when it is not a sequence."""
    return list(x) if isinstance(x, list) else []


def dig(x: object, *keys: str) -> object:
    """Follow `keys` through nested mappings; None when any step is missing."""
    for key in keys:
        if not isinstance(x, dict):
            return None
        x = x.get(key)
    return x


def as_strs(x: object) -> list[str]:
    """Return the string items of a list."""
    return [i for i in as_list(x) if isinstance(i, str)]


def lower_bound(spec: str) -> tuple[int, ...] | None:
    """The lowest version a spec allows: `>=3.12,<4` is (3, 12), `go1.25.3` is (1, 25, 3), `lts/*` is None."""
    for op, num in re.findall(r"([<>=~^!]*)\s*v?(\d+(?:\.\d+)*)", spec):
        if op not in {"<", "<=", "!="}:
            return tuple(int(p) for p in num.split("."))
    return None


def meets(actual: tuple[int, ...] | None, expected: str) -> bool:
    """Whether `actual` is at least the lower bound of `expected`, compared as numeric tuples."""
    want = lower_bound(expected)
    if actual is None or want is None:
        return False
    width = max(len(actual), len(want))
    return actual + (0,) * (width - len(actual)) >= want + (0,) * (width - len(want))


def tokens(value: str) -> set[str]:
    """The comma-separated parts of a value."""
    return {p.strip() for p in value.split(",") if p.strip()}


def has_tokens(value: str, expected: str) -> bool:
    """Whether every comma-separated part of `expected` is a part of `value`."""
    return tokens(expected) <= tokens(value)


def strip_jsonc(text: str) -> str:
    """Remove comments and trailing commas from JSON with comments (tsconfig), leaving strings alone."""
    text = text.removeprefix("﻿")
    out: list[str] = []
    i, n, comma = 0, len(text), -1
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i : j + 1])
            i, comma = j + 1, -1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
        else:
            if c == ",":
                comma = len(out)
            elif c in "}]":
                if comma >= 0:
                    out[comma] = ""
                comma = -1
            elif not c.isspace():
                comma = -1
            out.append(c)
            i += 1
    return "".join(out)


def float_as_str(constructor: BaseConstructor, node: ScalarNode) -> str:
    """Keep `3.10` as the string it was written as, not the float 3.1."""
    return str(constructor.construct_scalar(node))


def make_yaml() -> YAML:
    """The YAML 1.2 safe loader, with floats kept as written."""
    yaml = YAML(typ="safe", pure=True)
    yaml.constructor.add_constructor("tag:yaml.org,2002:float", float_as_str)
    return yaml


class Ctx:
    """The fetched files of one repo: reads are cached, and a file that could not be read raises Unreadable."""

    def __init__(self, root: Path, paths: Sequence[str], unreadable: Sequence[str]) -> None:
        """Index the tree paths and the unreadable ones of the repo fetched into `root`."""
        self.root = root
        self.paths = list(paths)
        self.pathset = set(paths)
        self.unreadable = set(unreadable)
        self._text: dict[str, str | None] = {}
        self._yaml = make_yaml()

    def has(self, path: str) -> bool:
        """Whether the tree has `path`."""
        return path in self.pathset

    def root_files(self, pattern: re.Pattern[str]) -> list[str]:
        """Tree paths at the repo root that match `pattern` completely, sorted."""
        return sorted(p for p in self.paths if "/" not in p and pattern.fullmatch(p))

    def anywhere(self, pattern: re.Pattern[str]) -> list[str]:
        """Tree paths anywhere that match `pattern` completely, sorted."""
        return sorted(p for p in self.paths if pattern.fullmatch(p))

    def text(self, path: str) -> str | None:
        """The file's text; None when the tree has no such file; Unreadable when it is there but cannot be read."""
        if path not in self._text:
            self._text[path] = self._read(path)
        return self._text[path]

    def _read(self, path: str) -> str | None:
        if path in self.unreadable:
            raise Unreadable(path)
        file = self.root / path
        if ".." in Path(path).parts or not file.is_file():
            if path in self.pathset:
                raise Unreadable(path)
            return None
        try:
            return file.read_text(encoding="utf-8", errors="replace")
        except OSError as err:
            raise Unreadable(path) from err

    def toml(self, path: str) -> dict[str, object] | None:
        """Parse a TOML file; None when missing."""
        text = self.text(path)
        if text is None:
            return None
        try:
            return tomllib.loads(text)
        except tomllib.TOMLDecodeError as err:
            raise Unparseable(path) from err

    def json(self, path: str, *, jsonc: bool = False) -> object:
        """Parse a JSON file (with comments and trailing commas when `jsonc`); None when missing."""
        text = self.text(path)
        if text is None:
            return None
        try:
            return json.loads(strip_jsonc(text) if jsonc else text)
        except (json.JSONDecodeError, RecursionError) as err:
            raise Unparseable(path) from err

    def yaml(self, path: str) -> object:
        """Parse a YAML file; None when missing."""
        text = self.text(path)
        if text is None:
            return None
        try:
            return self._yaml.load(text)
        except (YAMLError, ValueError, RecursionError) as err:
            raise Unparseable(path) from err

    def ini(self, path: str) -> configparser.ConfigParser | None:
        """Parse an INI file; None when missing."""
        text = self.text(path)
        if text is None:
            return None
        parser = configparser.ConfigParser(interpolation=None, strict=False)
        try:
            parser.read_string(text)
        except configparser.Error as err:
            raise Unparseable(path) from err
        return parser

    def workflows(self) -> list[str]:
        """The workflow files."""
        return self.anywhere(WORKFLOW)

    def ci_sources(self) -> list[str]:
        """The files where CI commands live: Makefile, workflows, pre-commit config."""
        files = [p for p in ("Makefile", ".pre-commit-config.yaml", ".pre-commit-config.yml") if self.has(p)]
        return files + self.workflows()

    def scan(self, pattern: str, paths: Sequence[str] | None = None) -> re.Match[str] | None:
        """The first match of `pattern` in the CI sources; Unreadable when nothing matched and a source was unread."""
        missed = ""
        for path in self.ci_sources() if paths is None else paths:
            try:
                text = self.text(path)
            except Unreadable:
                missed = path
                continue
            if text and (match := re.search(pattern, text, re.IGNORECASE)):
                return match
        if missed:
            raise Unreadable(missed)
        return None

    def ci_versions(self, uses: tuple[str, ...], key: str) -> list[str]:
        """The `key` input of the setup actions `uses` in the workflows, matrices expanded."""
        found: list[str] = []
        for path in self.workflows():
            for job in as_dict(as_dict(self.yaml(path)).get("jobs")).values():
                job_d = as_dict(job)
                matrix = as_dict(dig(job_d, "strategy", "matrix"))
                for step in as_list(job_d.get("steps")):
                    step_d = as_dict(step)
                    if str(step_d.get("uses", "")).startswith(uses):
                        found.extend(expand(as_dict(step_d.get("with")).get(key), matrix))
        return list(dict.fromkeys(found))


def expand(value: object, matrix: dict[str, object]) -> list[str]:
    """The strings a setup input can take: a scalar, a list, or `${{ matrix.x }}` looked up in the job's matrix."""
    if isinstance(value, list):
        return [s for v in value for s in expand(v, matrix)]
    if value is None or isinstance(value, dict):
        return []
    text = str(value).strip()
    if ref := re.fullmatch(r"\$\{\{\s*matrix\.([\w-]+)\s*\}\}", text):
        return [str(v) for v in as_list(matrix.get(ref.group(1)))]
    return [text]


# --- common -----------------------------------------------------------------------------------------------------


def make_targets(ctx: Ctx, exp: str) -> Result:
    """Which of help, lint, test and check the Makefile defines."""
    text = ctx.text("Makefile")
    if text is None:
        return Result("no Makefile", "absent")
    names: set[str] = set()
    for line in text.splitlines():
        if match := re.match(r"([A-Za-z0-9_.\- ]+?)\s*::?(?!=)", line):
            names.update(match.group(1).split())
    value = ", ".join(t for t in TARGETS if t in names) or "none"
    return Result(value, "same" if has_tokens(value, exp) else "differs")


def pre_commit(ctx: Ctx, _exp: str) -> Result:
    """Whether a pre-commit config exists."""
    found = ctx.has(".pre-commit-config.yaml") or ctx.has(".pre-commit-config.yml")
    return Result("present" if found else "absent", "same" if found else "absent")


def present(found: bool, exp: str) -> Result:  # noqa: FBT001
    """A present/absent value against an expectation."""
    value = "present" if found else "absent"
    return Result(value, "same" if value == exp else "absent" if not found else "differs")


def gitleaks(ctx: Ctx, exp: str) -> Result:
    """Whether the Makefile, a workflow or the pre-commit config runs gitleaks."""
    return present(ctx.scan("gitleaks") is not None, exp)


def dependabot_groups(ctx: Ctx, exp: str) -> Result:
    """The dependabot entries that have a version-update group, over all entries."""
    path = next((p for p in (".github/dependabot.yml", ".github/dependabot.yaml") if ctx.has(p)), None)
    if path is None:
        return Result("absent", "absent")
    entries = as_list(as_dict(ctx.yaml(path)).get("updates"))
    grouped = sum(
        any(as_dict(g).get("applies-to") != "security-updates" for g in as_dict(as_dict(e).get("groups")).values())
        for e in entries
    )
    value = f"{grouped}/{len(entries)}"
    ok = bool(entries) and grouped == len(entries)
    return Result(value, "same" if (ok if exp == "all" else value == exp) else "differs")


def ci_check_job(ctx: Ctx, exp: str) -> Result:
    """Whether ci.yml has a job named check."""
    files = ctx.anywhere(CI_FILE)
    if not files:
        return Result("no ci.yml", "absent")
    jobs = as_dict(as_dict(ctx.yaml(files[0])).get("jobs"))
    return present("check" in jobs, exp)


def docker_pins(ctx: Ctx, exp: str) -> Result:
    """The base images pinned by digest over all FROM lines of every Dockerfile."""
    files = ctx.anywhere(DOCKERFILE)
    if not files:
        return Result("no Dockerfile", "n.a.")
    pinned = total = 0
    for path in files:
        stages: set[str] = {"scratch"}
        for line in (ctx.text(path) or "").splitlines():
            match = re.match(r"\s*FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?", line, re.IGNORECASE)
            if not match:
                continue
            image = match.group(1)
            if image.lower() not in stages:
                total += 1
                pinned += "@sha256:" in image
            if match.group(2):
                stages.add(match.group(2).lower())
    value = f"{pinned}/{total}"
    if not total:
        return Result(value, "n.a.")
    return Result(value, "same" if (pinned == total if exp == "all" else value == exp) else "differs")


def release_tooling(ctx: Ctx, _exp: str) -> Result:
    """Whether release-please is configured."""
    found = ctx.has("release-please-config.json") or ctx.has(".release-please-manifest.json")
    return Result("release-please" if found else "none", "same" if found else "absent")


# --- python -----------------------------------------------------------------------------------------------------


def pyproject(ctx: Ctx) -> dict[str, object]:
    """The parsed pyproject.toml, empty when missing."""
    return ctx.toml("pyproject.toml") or {}


def python_applies(ctx: Ctx) -> bool:
    """Whether the repo has Python packaging files."""
    return ctx.has("pyproject.toml") or ctx.has("setup.py") or bool(ctx.root_files(REQUIREMENTS))


def python_deps(ctx: Ctx) -> set[str]:
    """Normalised names of every declared Python dependency (pyproject, poetry tables, requirements files)."""
    py = pyproject(ctx)
    specs: list[str] = as_strs(dig(py, "project", "dependencies")) + as_strs(dig(py, "tool", "uv", "dev-dependencies"))
    for group in (
        *as_dict(dig(py, "project", "optional-dependencies")).values(),
        *as_dict(py.get("dependency-groups")).values(),
    ):
        specs.extend(as_strs(group))
    poetry = as_dict(dig(py, "tool", "poetry"))
    names = list(as_dict(poetry.get("dependencies"))) + list(as_dict(poetry.get("dev-dependencies")))
    for group in as_dict(poetry.get("group")).values():
        names.extend(as_dict(as_dict(group).get("dependencies")))
    for path in ctx.root_files(REQUIREMENTS):
        specs.extend((ctx.text(path) or "").splitlines())
    names.extend(m.group(1) for s in specs if (m := re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", s)))
    return {re.sub(r"[-_.]+", "-", n).lower() for n in names}


def python_version(ctx: Ctx, exp: str) -> Result:
    """requires-python, .python-version and the Python versions CI sets up."""
    py = pyproject(ctx)
    requires = dig(py, "project", "requires-python") or dig(py, "tool", "poetry", "dependencies", "python")
    requires = requires if isinstance(requires, str) else ""
    pinned = ((ctx.text(".python-version") or "").strip().splitlines() or [""])[0].strip()
    ci = ctx.ci_versions(("actions/setup-python@", "astral-sh/setup-uv@"), "python-version")
    parts = [requires, f".python-version {pinned}" if pinned else "", f"ci {','.join(ci)}" if ci else ""]
    value = "; ".join(p for p in parts if p)
    if not requires and not pinned:
        return Result(value or "none", "absent")
    bound = lower_bound(requires) or lower_bound(pinned)
    return Result(value, "same" if meets(bound, exp) else "differs")


def python_pm(ctx: Ctx, exp: str) -> Result:
    """The package manager: uv, poetry or pip."""
    value = "uv" if ctx.has("uv.lock") else "poetry" if ctx.has("poetry.lock") else ""
    if not value:
        py = pyproject(ctx)
        backend = str(dig(py, "build-system", "build-backend") or "")
        if dig(py, "tool", "uv") is not None:
            value = "uv"
        elif dig(py, "tool", "poetry") is not None or "poetry" in backend:
            value = "poetry"
        else:
            value = "pip"
    return Result(value, "same" if value == exp else "differs")


def ruff_config(ctx: Ctx) -> dict[str, object] | None:
    """The ruff settings from ruff.toml, .ruff.toml or [tool.ruff]; None when there are none."""
    for path in ("ruff.toml", ".ruff.toml"):
        if ctx.has(path):
            return ctx.toml(path) or {}
    tool = dig(pyproject(ctx), "tool", "ruff")
    return as_dict(tool) if tool is not None else None


def count(n: int, noun: str) -> str:
    """`n` with its noun, pluralised."""
    return f"{n} {noun}" if n == 1 else f"{n} {noun}s"


def ruff(ctx: Ctx, exp: str) -> Result:
    """The ruff selection, ignores and line length."""
    cfg = ruff_config(ctx)
    if cfg is None:
        if "ruff" in python_deps(ctx):
            return Result("select=default", "differs")
        return Result("absent", "absent")
    lint = as_dict(cfg.get("lint"))
    select = as_strs(lint.get("select", cfg.get("select")))
    ignore = as_strs(lint.get("ignore", cfg.get("ignore")))
    if "ALL" in select:
        parts = ["select=ALL"]
    elif not select:
        parts = ["select=default"]
    else:
        parts = [f"select={','.join(select)}" if len(select) <= SHORT_LIST else f"select={count(len(select), 'rule')}"]
    if ignore:
        parts.append(f"ignore={count(len(ignore), 'rule')}")
    if (width := cfg.get("line-length")) is not None:
        parts.append(f"line-length={width}")
    value = ", ".join(parts)
    return Result(value, "same" if exp in parts else "differs")


def ruff_format(ctx: Ctx, exp: str) -> Result:
    """Whether the Makefile, CI or pre-commit runs `ruff format`."""
    return present(ctx.scan(r"ruff[^\n]*?\bformat\b|ruff-format") is not None, exp)


def mypy_config(ctx: Ctx) -> tuple[bool, int, int] | None:
    """(strict, overrides, overrides with ignore_errors) from the mypy config; None when there is none."""
    ini_boolean = {"1", "true", "yes", "on"}
    for path in ("mypy.ini", ".mypy.ini"):
        if (ini := ctx.ini(path)) is not None:
            return ini_mypy(ini, "mypy", ini_boolean)
    tool = dig(pyproject(ctx), "tool", "mypy")
    if tool is not None:
        cfg = as_dict(tool)
        overrides = [as_dict(o) for o in as_list(cfg.get("overrides"))]
        ignoring = sum(o.get("ignore_errors") is True for o in overrides)
        return cfg.get("strict") is True, len(overrides) - ignoring, ignoring
    if (ini := ctx.ini("setup.cfg")) is not None and ini.has_section("mypy"):
        return ini_mypy(ini, "mypy", ini_boolean)
    return None


def ini_mypy(ini: configparser.ConfigParser, section: str, truthy: set[str]) -> tuple[bool, int, int]:
    """Read the mypy settings of an INI file: the `[mypy]` section and its per-module `[mypy-*]` sections."""
    strict = ini.get(section, "strict", fallback="").strip().lower() in truthy
    others = [s for s in ini.sections() if s.startswith("mypy-")]
    ignoring = sum(ini.get(s, "ignore_errors", fallback="").strip().lower() in truthy for s in others)
    return strict, len(others) - ignoring, ignoring


def mypy(ctx: Ctx, exp: str) -> Result:
    """Whether mypy runs strict, and how many per-module overrides loosen it."""
    cfg = mypy_config(ctx)
    if cfg is None:
        if "mypy" not in python_deps(ctx) and ctx.scan(r"\bmypy\b") is None:
            return Result("absent", "absent")
        cfg = (False, 0, 0)
    strict, overrides, ignoring = cfg
    strict = strict or ctx.scan(r"\bmypy\b[^\n]*--strict") is not None
    parts = ["strict"] if strict else []
    if overrides:
        parts.append(count(overrides, "override"))
    if ignoring:
        parts.append(f"ignore_errors={ignoring}")
    value = ", ".join(parts) or "default"
    return Result(value, "same" if has_tokens(value, exp) else "differs")


def pytest(ctx: Ctx, exp: str) -> Result:
    """Whether pytest is configured or a dependency, with its plugins."""
    py = pyproject(ctx)
    setup = ctx.ini("setup.cfg")
    deps = python_deps(ctx)
    found = (
        ctx.has("pytest.ini")
        or dig(py, "tool", "pytest") is not None
        or (setup is not None and setup.has_section("tool:pytest"))
        or "pytest" in deps
    )
    if not found:
        return Result("absent", "absent")
    plugins = sorted(d for d in deps if d.startswith("pytest-"))
    value = ", ".join(plugins) or "pytest"
    return Result(value, "same" if exp.lower() in value.lower() else "differs")


def coverage_floor(ctx: Ctx, exp: str) -> Result:
    """The minimum coverage that fails the run (fail_under or --cov-fail-under)."""
    floor: object = dig(pyproject(ctx), "tool", "coverage", "report", "fail_under")
    for path, section in ((".coveragerc", "report"), ("setup.cfg", "coverage:report")):
        ini = ctx.ini(path)
        if floor is None and ini is not None and ini.has_option(section, "fail_under"):
            floor = ini.get(section, "fail_under")
    if floor is None and (
        match := ctx.scan(r"--cov-fail-under[= ]+(\d+(?:\.\d+)?)", [*ctx.ci_sources(), "pyproject.toml"])
    ):
        floor = match.group(1)
    if floor is None:
        return Result("absent", "absent")
    value = str(floor).strip()
    return Result(value, "same" if meets(lower_bound(value), exp) else "differs")


# --- js ---------------------------------------------------------------------------------------------------------


def package_json(ctx: Ctx) -> dict[str, object]:
    """The parsed package.json, empty when missing."""
    return as_dict(ctx.json("package.json"))


def js_deps(ctx: Ctx) -> dict[str, str]:
    """Every dependency of package.json (all kinds) with its spec."""
    pkg = package_json(ctx)
    deps: dict[str, str] = {}
    for kind in ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies"):
        deps.update({k: v for k, v in as_dict(pkg.get(kind)).items() if isinstance(v, str)})
    return deps


def node_version(ctx: Ctx, exp: str) -> Result:
    """engines.node, .nvmrc or .node-version, and the Node versions CI sets up."""
    engines = dig(package_json(ctx), "engines", "node")
    engines = engines if isinstance(engines, str) else ""
    pinned_file = next((f for f in (".nvmrc", ".node-version") if ctx.has(f)), "")
    pinned = ((ctx.text(pinned_file) or "").strip().splitlines() or [""])[0].strip() if pinned_file else ""
    ci = ctx.ci_versions(("actions/setup-node@",), "node-version")
    parts = [
        f"engines {engines}" if engines else "",
        f"{pinned_file} {pinned}" if pinned else "",
        f"ci {','.join(ci)}" if ci else "",
    ]
    value = "; ".join(p for p in parts if p)
    if not engines and not pinned:
        return Result(value or "none", "absent")
    return Result(value, "same" if meets(lower_bound(engines) or lower_bound(pinned), exp) else "differs")


def js_pm(ctx: Ctx, exp: str) -> Result:
    """The package manager, from the lock file or the packageManager field."""
    locks = {"pnpm-lock.yaml": "pnpm", "yarn.lock": "yarn", "package-lock.json": "npm", "bun.lock": "bun"}
    value = next((name for lock, name in locks.items() if ctx.has(lock)), "")
    if not value:
        declared = dig(package_json(ctx), "packageManager")
        value = declared.split("@")[0] if isinstance(declared, str) and declared else ""
    if not value:
        return Result("none", "absent")
    return Result(value, "same" if value == exp else "differs")


def typescript(ctx: Ctx, exp: str) -> Result:
    """The TypeScript major version declared in package.json."""
    spec = js_deps(ctx).get("typescript")
    if spec is None:
        return Result("absent", "absent")
    bound = lower_bound(spec)
    return Result(str(bound[0]) if bound else spec, "same" if meets(bound, exp) else "differs")


def eslint(ctx: Ctx, exp: str) -> Result:
    """The ESLint config kind (flat or eslintrc) and the major version declared."""
    flat = ctx.root_files(ESLINT_FLAT)
    legacy = ctx.root_files(ESLINT_RC) or (["eslintConfig"] if "eslintConfig" in package_json(ctx) else [])
    spec = js_deps(ctx).get("eslint")
    if not flat and not legacy and spec is None:
        return Result("absent", "absent")
    kind = "flat" if flat else "eslintrc" if legacy else "no config"
    bound = lower_bound(spec) if spec else None
    value = f"{kind} v{bound[0]}" if bound else kind
    return Result(value, "same" if meets(bound, exp) else "differs")


def prettier(ctx: Ctx, exp: str) -> Result:
    """Whether Prettier is configured or a dependency."""
    found = bool(ctx.root_files(PRETTIER)) or "prettier" in package_json(ctx) or "prettier" in js_deps(ctx)
    return present(found, exp)


def tsconfig_options(ctx: Ctx, path: str, depth: int = 0) -> dict[str, object]:
    """The compilerOptions of a tsconfig merged over those of the root-level files it extends."""
    cfg = as_dict(ctx.json(path, jsonc=True))
    options: dict[str, object] = {}
    extends = cfg.get("extends")
    for ref in [extends] if isinstance(extends, str) else as_strs(extends):
        base = ref.removeprefix("./")
        base = base if base.endswith(".json") else f"{base}.json"
        if depth < SHORT_LIST and "/" not in base and ctx.has(base):
            options.update(tsconfig_options(ctx, base, depth + 1))
    options.update(as_dict(cfg.get("compilerOptions")))
    return options


def tsconfig_strict(ctx: Ctx, exp: str) -> Result:
    """Whether the root tsconfig is strict, and which extra strictness flags it sets."""
    files = ctx.root_files(TSCONFIG)
    if not files:
        return Result("absent", "absent")
    options = tsconfig_options(ctx, "tsconfig.json" if "tsconfig.json" in files else files[0])
    parts = ["strict" if options.get("strict") is True else "not strict"]
    parts.extend(f for f in TS_FLAGS if options.get(f) is True)
    value = ", ".join(parts)
    return Result(value, "same" if has_tokens(value, exp) else "differs")


def test_runner(ctx: Ctx, exp: str) -> Result:
    """The JS test runner: vitest, jest, both or none."""
    deps = js_deps(ctx)
    pkg = package_json(ctx)
    found = {name for name in ("vitest", "jest") if name in deps}
    for path in ctx.root_files(JS_TEST_CONFIG):
        found.update(name for name in ("vitest", "jest") if path.startswith(f"{name}."))
    if "jest" in pkg:
        found.add("jest")
    value = ", ".join(sorted(found, reverse=True)) or "none"
    if not found:
        return Result(value, "absent")
    return Result(value, "same" if exp in found else "differs")


# --- go ---------------------------------------------------------------------------------------------------------


def go_version(ctx: Ctx, exp: str) -> Result:
    """The go directive and the toolchain directive of go.mod."""
    text = ctx.text("go.mod") or ""
    go = re.search(r"^go\s+(\S+)", text, re.MULTILINE)
    toolchain = re.search(r"^toolchain\s+(\S+)", text, re.MULTILINE)
    if go is None:
        return Result("no go directive", "differs")
    value = f"go {go.group(1)}" + (f"; toolchain {toolchain.group(1)}" if toolchain else "")
    return Result(value, "same" if meets(lower_bound(go.group(1)), exp) else "differs")


def golangci_lint(ctx: Ctx, exp: str) -> Result:
    """The golangci-lint config version, the linters it enables and the CI action version."""
    files = ctx.root_files(GOLANGCI)
    if not files:
        return Result("absent", "absent")
    path = files[0]
    cfg = as_dict(
        ctx.yaml(path)
        if path.endswith(("yml", "yaml"))
        else ctx.toml(path)
        if path.endswith("toml")
        else ctx.json(path)
    )
    version = str(cfg.get("version", "1")).strip()
    linters = as_dict(cfg.get("linters"))
    parts = [f"v{version}"]
    if "default" in linters:
        parts.append(f"default={linters['default']}")
    if linters.get("enable-all") is True:
        parts.append("enable-all")
    if linters.get("disable-all") is True:
        parts.append("disable-all")
    if enabled := as_strs(linters.get("enable")):
        parts.append(f"{len(enabled)} enabled")
    if len(parts) == 1:
        parts.append("default linters")
    try:
        action = ctx.scan(r"golangci/golangci-lint-action@\S+[ \t]+#[ \t]*(v?\d[\w.]*)", ctx.workflows())
    except Unreadable:
        action = None
    if action:
        parts.append(f"action {action.group(1)}")
    return Result(", ".join(parts), "same" if meets(lower_bound(version), exp) else "differs")


def golangci_baseline(ctx: Ctx, _exp: str) -> Result:
    """Whether a golangci-lint baseline file is committed."""
    files = ctx.root_files(GOLANGCI_BASELINE)
    return Result(f"present ({files[0]})" if files else "absent", "same" if files else "absent")


def applies_js(ctx: Ctx) -> bool:
    """Whether the repo has a package.json."""
    return ctx.has("package.json")


def applies_go(ctx: Ctx) -> bool:
    """Whether the repo has a go.mod."""
    return ctx.has("go.mod")


APPLIES: dict[str, Callable[[Ctx], bool]] = {
    "common": lambda _ctx: True,
    "python": python_applies,
    "js": applies_js,
    "go": applies_go,
}

CHECKS: tuple[Check, ...] = (
    Check("make_targets", "common", "help, lint, test, check", make_targets),
    Check("pre_commit", "common", None, pre_commit),
    Check("gitleaks", "common", "present", gitleaks),
    Check("dependabot_groups", "common", "all", dependabot_groups),
    Check("ci_check_job", "common", "present", ci_check_job),
    Check("docker_pins", "common", "all", docker_pins),
    Check("release_tooling", "common", "release-please", release_tooling),
    Check("python_version", "python", ">=3.14", python_version),
    Check("python_pm", "python", "uv", python_pm),
    Check("ruff", "python", "select=ALL", ruff),
    Check("ruff_format", "python", "present", ruff_format),
    Check("mypy", "python", "strict", mypy),
    Check("pytest", "python", None, pytest),
    Check("coverage_floor", "python", None, coverage_floor),
    Check("node_version", "js", ">=26", node_version),
    Check("js_pm", "js", "pnpm", js_pm),
    Check("typescript", "js", "7", typescript),
    Check("eslint", "js", "10", eslint),
    Check("prettier", "js", "present", prettier),
    Check("tsconfig_strict", "js", "strict", tsconfig_strict),
    Check("test_runner", "js", "vitest", test_runner),
    Check("go_version", "go", ">=1.26", go_version),
    Check("golangci_lint", "go", "v2", golangci_lint),
    Check("golangci_baseline", "go", None, golangci_baseline),
)
IDS = {c.tool_id for c in CHECKS}


# --- config -----------------------------------------------------------------------------------------------------


class ConfigError(Exception):
    """standard/tooling.json is invalid."""


def check_keys(where: str, obj: object, allowed: set[str]) -> dict[str, object]:
    """Require a JSON object whose keys are all in `allowed`."""
    if not isinstance(obj, dict):
        msg = f"{where}: expected an object"
        raise ConfigError(msg)
    unknown = sorted(set(obj) - allowed)
    if unknown:
        msg = f"{where}: unknown key {', '.join(unknown)}"
        raise ConfigError(msg)
    return {str(k): v for k, v in obj.items()}


def check_overrides(where: str, obj: object) -> dict[str, dict[str, str]]:
    """Validate a `checks` table: tool ids to {severity, expected}."""
    out: dict[str, dict[str, str]] = {}
    for tool_id, entry in check_keys(where, obj, IDS).items():
        fields = check_keys(f"{where}.{tool_id}", entry, {"severity", "expected"})
        for key, val in fields.items():
            if not isinstance(val, str) or (key == "severity" and val not in SEVERITIES):
                msg = f"{where}.{tool_id}.{key}: invalid value {val!r}" + (
                    f" (one of {', '.join(SEVERITIES)})" if key == "severity" else ""
                )
                raise ConfigError(msg)
        out[tool_id] = {k: str(v) for k, v in fields.items()}
    return out


def check_id_list(where: str, obj: object, allowed: set[str] | None) -> list[str]:
    """Validate a list of tool ids (or repo names when `allowed` is None)."""
    if not isinstance(obj, list) or not all(isinstance(i, str) for i in obj):
        msg = f"{where}: expected a list of strings"
        raise ConfigError(msg)
    items = [str(i) for i in obj]
    bad = [i for i in items if allowed is not None and i not in allowed]
    if bad:
        msg = f"{where}: unknown tool id {', '.join(bad)}"
        raise ConfigError(msg)
    return items


@dataclass
class Config:
    """The validated standard/tooling.json."""

    checks: dict[str, dict[str, str]]
    repos: dict[str, dict[str, dict[str, str]]]
    repo_ignore: dict[str, list[str]]
    ignore_repos: list[str]
    ignore_checks: list[str]


def load_config(path: Path) -> Config:
    """Read and validate the config; ConfigError on anything unexpected, so a typo never passes silently."""
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as err:
        msg = f"{path}: {err}"
        raise ConfigError(msg) from err
    top = check_keys(str(path), raw, {"checks", "repos", "ignore"})
    checks = check_overrides("checks", top.get("checks", {}))
    ignore = check_keys("ignore", top.get("ignore", {}), {"repos", "checks"})
    repos: dict[str, dict[str, dict[str, str]]] = {}
    repo_ignore: dict[str, list[str]] = {}
    for repo, entry in check_keys("repos", top.get("repos", {}), set(as_dict(top.get("repos")))).items():
        fields = check_keys(f"repos.{repo}", entry, {"checks", "ignore"})
        repos[repo] = check_overrides(f"repos.{repo}.checks", fields.get("checks", {}))
        repo_ignore[repo] = check_id_list(f"repos.{repo}.ignore", fields.get("ignore", []), IDS)
    return Config(
        checks,
        repos,
        repo_ignore,
        check_id_list("ignore.repos", ignore.get("repos", []), None),
        check_id_list("ignore.checks", ignore.get("checks", []), IDS),
    )


# --- collect ----------------------------------------------------------------------------------------------------


def run_check(check: Check, ctx: Ctx, repo: str, released: bool, config: Config) -> dict[str, str | None]:  # noqa: FBT001
    """One cell: the collector's value and status, adjusted by the config's expectation, severity and ignores."""
    chosen = {**config.checks.get(check.tool_id, {}), **config.repos.get(repo, {}).get(check.tool_id, {})}
    severity = chosen.get("severity", "info")
    expected = chosen.get("expected", check.expected)
    if check.tool_id == "release_tooling" and not released:
        expected = None
    cell: dict[str, str | None] = {
        "group": check.group,
        "value": "",
        "expected": None,
        "status": "n.a.",
        "severity": severity,
    }
    if not APPLIES[check.group](ctx):
        return cell
    ignored = check.tool_id in config.ignore_checks or check.tool_id in config.repo_ignore.get(repo, [])
    try:
        result = check.collect(ctx, expected or "")
    except Unreadable:
        result = Result("cannot read", "unknown")
    except (Unparseable, AttributeError, TypeError, ValueError, KeyError, IndexError):
        result = Result("unparseable", "unknown")
    cell["value"] = result.value
    if ignored:
        return cell
    cell["expected"] = expected
    cell["status"] = result.status if result.status == "unknown" or expected is not None else "n.a."
    return cell


def collect(args: argparse.Namespace) -> int:
    """Print the cells of one repo as one JSON object."""
    try:
        config = load_config(Path(args.config))
    except ConfigError as err:
        sys.stderr.write(f"tooling.py: config error: {err}\n")
        return 2
    if args.repo in config.ignore_repos:
        sys.stdout.write("{}\n")
        return 0
    root = Path(args.dir)
    audit = root / ".audit"
    if not (audit / "paths").is_file():
        sys.stderr.write(f"tooling.py: {audit / 'paths'} missing\n")
        return 2
    paths = [p for p in (audit / "paths").read_text(encoding="utf-8", errors="replace").splitlines() if p]
    unreadable_file = audit / "unreadable"
    unreadable = (
        unreadable_file.read_text(encoding="utf-8", errors="replace").splitlines() if unreadable_file.is_file() else []
    )
    ctx = Ctx(root, paths, [u for u in unreadable if u])
    released = args.released == "true"
    cells = {c.tool_id: run_check(c, ctx, args.repo, released, config) for c in CHECKS}
    sys.stdout.write(json.dumps(cells) + "\n")
    return 0


def wanted(_args: argparse.Namespace) -> int:
    """Print the tree paths on stdin that the collectors read."""
    for line in sys.stdin.read().splitlines():
        if WANTED.fullmatch(line):
            sys.stdout.write(line + "\n")
    return 0


def main() -> int:
    """Parse the command line and run a subcommand."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else "")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("wanted").set_defaults(run=wanted)
    cmd = sub.add_parser("collect")
    cmd.add_argument("--repo", required=True)
    cmd.add_argument(
        "--type", required=True, choices=["python", "typescript", "go", "infra", "config", "docs", "unknown"]
    )
    cmd.add_argument("--released", required=True, choices=["true", "false"])
    cmd.add_argument("--config", required=True)
    cmd.add_argument("dir")
    cmd.set_defaults(run=collect)
    args = parser.parse_args()
    return int(args.run(args))


if __name__ == "__main__":
    sys.exit(main())
