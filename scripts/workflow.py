# /// script
# requires-python = ">=3.12"
# dependencies = ["ruamel.yaml==0.19.1"]
# ///
"""CI hygiene of one GitHub Actions workflow or action metadata file (docs/standard.md, CI hygiene).

Reads the file on stdin and parses it with a real YAML 1.2 parser (ruamel.yaml, pinned above and in
workflow.py.lock); run it as `uv run --script --locked scripts/workflow.py < file`. It prints one
tab-separated line per result and exits 0; any other exit is a crash, which the audit treats as a
broken run (exit 2), never as a pass:

    wf_parsed       <detail>   the file is not a workflow this checker can read; it fails closed
    wf_permissions  <detail>
    wf_timeout      <detail>
    wf_concurrency  <detail>
    wf_pinned       <detail>
    pin             <owner/repo> <sha> <version>   an accepted pin, for sync.sh to verify upstream
    local           <path>                          a `./` ref, for sync.sh to find and check in the repo

A file whose top level has `runs` and no `jobs` is action metadata (`action.yml`): only its `uses`
and `image` refs are checked.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field

from ruamel.yaml import YAML
from ruamel.yaml.error import YAMLError
from ruamel.yaml.events import CollectionStartEvent, ScalarEvent
from ruamel.yaml.nodes import MappingNode, Node, ScalarNode, SequenceNode

STR = "tag:yaml.org,2002:str"
INT = "tag:yaml.org,2002:int"
BOOL = "tag:yaml.org,2002:bool"
NULL = "tag:yaml.org,2002:null"
MERGE = "tag:yaml.org,2002:merge"
# Line breaks other than LF, left after CRLF is folded: YAML parsers disagree on them, so they fail closed.
BREAKS = {"\r": "CR", "\x85": "NEL", "\u2028": "LS", "\u2029": "PS"}
REMOTE = re.compile(r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+(/[^@\s]+)?@[0-9a-f]{40}")
DOCKER = re.compile(r"docker://[^@\s]+@sha256:[0-9a-f]{64}")
LOCAL = re.compile(r"\./[^\s]*")
VERSION = re.compile(r"\s+#\s*(v?[0-9]+(?:\.[0-9]+)*)\s*")
EXPR = re.compile(r"\$\{\{(.*)\}\}", re.DOTALL)
RUN_ID = re.compile(r"\$\{\{[^}]*\bgithub\.run_id\b[^}]*\}\}")
LEVELS = {"read", "write", "none"}
PR_EVENTS = {"pull_request", "pull_request_target"}
# their runs are never cancelled or replaced; a reusable workflow (workflow_call) runs in its caller's context, whose
# event may be one of them
GUARDED_EVENTS = {"push", "merge_group", "workflow_call"}
MINUTES = re.compile(r"[1-9][0-9]*")  # plain decimal: YAML 1.2 core reads `1_0`, `0b101`, `0x_1` as strings
ONE_EXPR = re.compile(r"\$\{\{([^}]*)\}\}")
CONSTANT = re.compile(r"-?[0-9.]+|'[^']*'|true|false|null")
IMAGE = re.compile(r"[^@\s]+@sha256:[0-9a-f]{64}")


class UnreadableError(Exception):
    """The file is outside what this checker reads; reported as `wf_parsed`."""


def tag(node: Node) -> str:
    """Return the node's resolved tag as a string."""
    return str(node.tag)


def text(node: Node | None) -> str | None:
    """Return a string scalar's value, or None for any other node."""
    if isinstance(node, ScalarNode) and tag(node) == STR:
        return str(node.value)
    return None


def pairs(node: Node, where: str) -> dict[str, Node]:
    """Return a mapping node's entries by key; reject merge keys, non-string and duplicate keys."""
    if not isinstance(node, MappingNode):
        msg = f"{where}: not a mapping"
        raise UnreadableError(msg)
    out: dict[str, Node] = {}
    for key, value in node.value:
        if tag(key) == MERGE:
            msg = f"{where}: merge key `<<`"
            raise UnreadableError(msg)
        name = text(key)
        if name is None:
            msg = f"{where}: a key that is not a string"
            raise UnreadableError(msg)
        if name in out:
            msg = f"{where}: duplicate key {name}"
            raise UnreadableError(msg)
        out[name] = value
    return out


def items(node: Node, where: str) -> list[Node]:
    """Return a sequence node's items."""
    if not isinstance(node, SequenceNode):
        msg = f"{where}: not a list"
        raise UnreadableError(msg)
    return list(node.value)


def is_true(node: Node) -> bool:
    """Tell whether a `cancel-in-progress` value is a literal true (`true`, `"true"`, `${{ true }}`, ...)."""
    if not isinstance(node, ScalarNode):
        return True  # not a scalar: fail closed
    if tag(node) == BOOL:
        return str(node.value).lower() == "true"
    value = str(node.value).strip()
    match = EXPR.fullmatch(value)
    if match:
        value = match.group(1).strip().strip("'\"")
    return value.lower() in {"true", "yes", "on"}


@dataclass(slots=True)
class Checker:
    """Collects the results for one file."""

    lines: list[str]
    findings: dict[str, list[str]] = field(default_factory=dict)
    pins: list[str] = field(default_factory=list)
    locals: list[str] = field(default_factory=list)

    def bad(self, check: str, detail: str) -> None:
        """Record a failed rule."""
        self.findings.setdefault(check, []).append(detail)

    def ref(self, node: Node, where: str) -> None:
        """Check one `uses` (or docker `image`) ref and its version comment."""
        value = text(node)
        if value is None:
            msg = f"{where}: uses is not a string"
            raise UnreadableError(msg)
        if value.startswith("./"):
            if not LOCAL.fullmatch(value) or "/../" in f"{value}/":
                self.bad("wf_pinned", f"local ref not read: {value}")
            else:
                self.locals.append(value)
            return
        if value.startswith("docker://"):
            if not DOCKER.fullmatch(value):
                self.bad("wf_pinned", f"docker image not pinned by sha256 digest: {value}")
            return
        if not REMOTE.fullmatch(value):
            self.bad("wf_pinned", f"not pinned by SHA: {value}")
            return
        if {".", ".."} & set(value.rsplit("@", 1)[0].split("/")):  # the runner joins the path without a check
            self.bad("wf_pinned", f"`.` or `..` path segment in a remote ref: {value}")
            return
        end = node.end_mark
        comment = VERSION.fullmatch(self.lines[end.line][end.column :]) if end.line < len(self.lines) else None
        if comment is None:
            self.bad("wf_pinned", f"no version comment: {value}")
            return
        action, sha = value.rsplit("@", 1)
        repo = "/".join(action.split("/")[:2])
        self.pins.append(f"{repo}\t{sha}\t{comment.group(1)}")

    def permissions(self, node: Node, where: str) -> None:
        """Check a permissions value: read-all, a scope map, never write-all."""
        value = text(node)
        if value == "write-all":
            self.bad("wf_permissions", f"{where}: permissions: write-all")
        elif value == "read-all":
            return
        elif isinstance(node, MappingNode):
            for scope, level in pairs(node, f"{where} permissions").items():
                if text(level) not in LEVELS:
                    msg = f"{where}: permissions {scope} is not read, write or none"
                    raise UnreadableError(msg)
        else:
            self.bad("wf_permissions", f"{where}: permissions is not read-all or a scope map")

    def concurrency(self, node: Node, where: str, *, guarded: bool) -> None:
        """Check a concurrency value; push and merge_group runs need a per-run group and no literal cancel."""
        group: Node | None = node
        cancel: Node | None = None
        if isinstance(node, MappingNode):
            entries = pairs(node, f"{where} concurrency")
            group, cancel = entries.get("group"), entries.get("cancel-in-progress")
        if text(group) is None:
            msg = f"{where}: concurrency group is not a string"
            raise UnreadableError(msg)
        if not guarded:
            return
        if not RUN_ID.search(text(group) or ""):
            self.bad(
                "wf_concurrency",
                f"{where}: group without ${{{{ github.run_id }}}} on a push, merge_group or workflow_call run",
            )
        if cancel is not None and is_true(cancel):
            self.bad("wf_concurrency", f"{where}: cancel-in-progress: true on a push, merge_group or workflow_call run")

    def steps(self, node: Node, where: str) -> None:
        """Check the `uses` of every step."""
        for i, step in enumerate(items(node, f"{where} steps")):
            entries = pairs(step, f"{where} step {i + 1}")
            if "uses" in entries:
                self.ref(entries["uses"], f"{where} step {i + 1}")

    def triggers(self, node: Node) -> set[str]:
        """Return the event names under `on:`."""
        value = text(node)
        if value is not None:
            return {value}
        if isinstance(node, SequenceNode):
            names = {text(item) for item in items(node, "on")}
            if None in names:
                msg = "on: a trigger that is not a string"
                raise UnreadableError(msg)
            return {name for name in names if name is not None}
        return set(pairs(node, "on"))

    def workflow(self, root: dict[str, Node]) -> None:
        """Check a workflow file."""
        if "on" not in root:
            msg = "no on:"
            raise UnreadableError(msg)
        events = self.triggers(root["on"])
        guarded = bool(events & GUARDED_EVENTS)
        if "permissions" in root:
            self.permissions(root["permissions"], "top level")
        else:
            self.bad("wf_permissions", "no top-level permissions")
        top_concurrency = "concurrency" in root
        if top_concurrency:
            self.concurrency(root["concurrency"], "top level", guarded=guarded)
        jobs = pairs(root["jobs"], "jobs")
        if not jobs:
            msg = "no job under jobs:"
            raise UnreadableError(msg)
        untimed = [name for name, job in jobs.items() if not self.job(name, job, guarded=guarded)]
        unconcurrent = any("concurrency" not in pairs(job, f"job {name}") for name, job in jobs.items())
        if untimed:
            self.bad("wf_timeout", "jobs without a positive timeout-minutes: " + ", ".join(untimed))
        if events & PR_EVENTS and not top_concurrency and unconcurrent:
            self.bad("wf_concurrency", "pull_request trigger without concurrency")

    def job(self, name: str, node: Node, *, guarded: bool) -> bool:
        """Check one job; return whether it has the timeout it needs."""
        job = pairs(node, f"job {name}")
        where = f"job {name}"
        if "permissions" in job:
            self.permissions(job["permissions"], where)
        if "concurrency" in job:
            self.concurrency(job["concurrency"], where, guarded=guarded)
        if "uses" in job:  # a reusable workflow call; it cannot set timeout-minutes
            self.ref(job["uses"], where)
            return True
        if "steps" in job:
            self.steps(job["steps"], where)
        self.images(job, where)
        return positive_minutes(job.get("timeout-minutes"))

    def images(self, job: dict[str, Node], where: str) -> None:
        """Check the job's container and service images: pinned by digest."""
        found: list[tuple[Node, str]] = []
        if "container" in job:
            found.append((job["container"], f"{where} container"))
        if "services" in job:
            found += [(service, f"{where} service {name}") for name, service in pairs(job["services"], where).items()]
        for node, label in found:
            image = node if isinstance(node, ScalarNode) else pairs(node, label).get("image")
            value = text(image)
            if value is None:
                msg = f"{label}: image is not a string"
                raise UnreadableError(msg)
            if not IMAGE.fullmatch(value.removeprefix("docker://")):
                self.bad("wf_pinned", f"{label}: image not pinned by sha256 digest: {value}")

    def action(self, root: dict[str, Node]) -> None:
        """Check action metadata: composite steps and a docker image."""
        runs = pairs(root["runs"], "runs")
        if "steps" in runs:
            self.steps(runs["steps"], "runs")
        image = text(runs.get("image"))
        if image is not None and image.startswith("docker://"):
            self.ref(runs["image"], "runs image")


def positive_minutes(node: Node | None) -> bool:
    """Tell whether a `timeout-minutes` value is a plain positive integer or one non-constant expression."""
    if not isinstance(node, ScalarNode):
        return False
    if tag(node) == INT:
        return bool(MINUTES.fullmatch(str(node.value)))
    match = ONE_EXPR.fullmatch(text(node) or "")
    return match is not None and not CONSTANT.fullmatch(match.group(1).strip())


def check_mappings(node: Node, seen: set[int]) -> None:
    """Reject merge keys, non-string keys and duplicate keys anywhere in the file, aliases followed once."""
    if id(node) in seen:
        return
    seen.add(id(node))
    if isinstance(node, MappingNode):
        pairs(node, f"line {node.start_mark.line + 1}")
        for key, value in node.value:
            check_mappings(key, seen)
            check_mappings(value, seen)
    elif isinstance(node, SequenceNode):
        for item in node.value:
            check_mappings(item, seen)


def check_tags(yaml: YAML, source: str) -> None:
    """Reject explicit tags (`!!bool`, `!x`): GitHub's parser may resolve them differently."""
    for event in yaml.parse(source):
        if isinstance(event, ScalarEvent | CollectionStartEvent) and event.tag is not None:
            msg = f"line {event.start_mark.line + 1}: explicit tag {event.tag}"
            raise UnreadableError(msg)


def load(raw: bytes, checker: Checker) -> dict[str, Node]:
    """Decode and parse one file into its top-level entries; raise UnreadableError or YAMLError."""
    try:
        source = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        msg = "not UTF-8"
        raise UnreadableError(msg) from exc
    source = source.removeprefix("\ufeff").replace("\r\n", "\n")  # a leading BOM is dropped, as YAML does
    for char, name in BREAKS.items():
        if char in source:
            line = source[: source.index(char)].count("\n") + 1
            msg = f"line {line}: {name} line break (only LF and CRLF are read)"
            raise UnreadableError(msg)
    checker.lines = source.split("\n")
    yaml = YAML(typ="safe", pure=True)
    check_tags(yaml, source)
    documents = list(yaml.compose_all(source))
    if len(documents) != 1 or documents[0] is None:
        msg = "not exactly one YAML document"
        raise UnreadableError(msg)
    check_mappings(documents[0], set())
    return pairs(documents[0], "top level")


def run(raw: bytes, *, action: bool) -> list[str]:
    """Check one file, a workflow or (`action`) action metadata, and return its result lines.

    The kind comes from the file's path, never from its content: an action.yml that also carries `jobs:` must not be
    read as a workflow, which would leave its `runs` unchecked.
    """
    checker = Checker(lines=[])
    try:
        root = load(raw, checker)
        if "jobs" in root and "runs" in root:
            checker.bad("wf_parsed", "both jobs: and runs: at the top level")
        elif action and "runs" in root:
            checker.action(root)
        elif not action and "jobs" in root:
            checker.workflow(root)
        else:
            checker.bad("wf_parsed", "action metadata without runs:" if action else "workflow without jobs:")
    except UnreadableError as exc:
        checker.bad("wf_parsed", str(exc))
    except YAMLError as exc:
        checker.bad("wf_parsed", "YAML: " + " ".join(str(exc).split()))
    order = ["wf_parsed", "wf_permissions", "wf_timeout", "wf_concurrency", "wf_pinned"]
    out = [f"{check}\t{'; '.join(checker.findings[check])}" for check in order if check in checker.findings]
    if "wf_parsed" not in checker.findings:
        out += [f"pin\t{pin}" for pin in checker.pins] + [f"local\t{path}" for path in checker.locals]
    return out


if __name__ == "__main__":
    if sys.argv[1:] not in ([], ["--action"]):
        sys.exit("usage: workflow.py [--action] < file")
    for result in run(sys.stdin.buffer.read(), action=sys.argv[1:] == ["--action"]):
        sys.stdout.write(result + "\n")
