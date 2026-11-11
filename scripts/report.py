# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Render the audit JSON (`scripts/sync.sh audit --json`) as a GitHub Markdown issue body.

    uv run --quiet --script scripts/report.py [--date YYYY-MM-DD] [--run-url URL] < audit.json > body.md

Sections: summary, Drift, Unknown (cannot read), How to fix, Tooling. The order is stable, so the issue body
changes little between runs. A private repo is never named (`private repo N`). The body stays under the GitHub
issue limit: Tooling is dropped first, then table rows are cut.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from dataclasses import dataclass, field
from typing import Any

MAX_BODY = 60000  # GitHub issue bodies hold 65536 chars
MAX_ITEMS = 8
SETTING = re.compile(r"([A-Za-z0-9_]+): (.*) \(want (.*)\)")
HEADER = "| check | repo | found | wanted | status |\n| --- | --- | --- | --- | --- |"
GROUPS = (("common", "Common"), ("python", "Python"), ("js", "JS/TS"), ("go", "Go"))

WANTED = {
    "wf_pinned": "every uses: pinned by full SHA with a version comment",
    "wf_parsed": "a workflow file the checker can parse",
    "wf_permissions": "top-level or per-job permissions, least privilege",
    "wf_timeout": "timeout-minutes on every job",
    "wf_concurrency": "a concurrency group per workflow",
    "squash_only": "squash merge only, title PR_TITLE, body PR_BODY",
    "delete_branch": "delete branch on merge",
    "dependabot_alerts": "Dependabot alerts enabled",
    "dependabot_security_updates": "Dependabot security updates enabled",
    "secret_scanning": "secret scanning and push protection enabled",
    "vuln_reporting": "private vulnerability reporting enabled",
    "ruleset_main": "ruleset main with the required checks",
    "labels": "the standard labels (plus the repo extras), no others",
    "agent_ignore": "the agent ignore lines in .gitignore",
    "no_claude_md": "no tracked CLAUDE.md",
    "agents_md": "an AGENTS.md",
    "dependabot": "a .github/dependabot.yml",
    "make_check": "a Makefile check target",
    "gitleaks": "gitleaks in ci.yml",
    "ci_check_job": "a ci.yml job check with needs and if: always()",
    "pr_title": "standard/workflows/pr-title.yml (refs may differ by verified bumps)",
    "label_guard": "standard/workflows/label-guard.yml (refs may differ by verified bumps)",
    "todo_issues": "standard/workflows/todo-issues.yml (refs may differ by verified bumps)",
    "todo_issues_branch": "default branch main or master",
    "repo_type": "exactly one std-<type> topic",
    "python_toolchain": "uv.lock, ruff, mypy and pytest",
    "go_toolchain": "go vet, golangci-lint run, go test -race and govulncheck in ci.yml or Makefile",
    "dependabot_grouped": "a version-update group on every updates entry",
    "dependabot_prefix": "a Conventional Commit commit-message.prefix on every updates entry",
}
SETTINGS_FIX = "`scripts/sync.sh apply settings <repo>`"
FIX = {
    "squash_only": SETTINGS_FIX,
    "delete_branch": SETTINGS_FIX,
    "auto_merge": SETTINGS_FIX,
    "dependabot_alerts": SETTINGS_FIX,
    "dependabot_security_updates": SETTINGS_FIX,
    "secret_scanning": SETTINGS_FIX,
    "vuln_reporting": SETTINGS_FIX,
    "labels": "`scripts/sync.sh apply labels <repo>`",
    "pr_title": "`scripts/sync.sh apply workflows <repo>`",
    "label_guard": "`scripts/sync.sh apply workflows <repo>`",
    "todo_issues": "`scripts/sync.sh apply workflows <repo>`",
    "agent_ignore": "`scripts/sync.sh apply gitignore <repo>`",
    "no_claude_md": "`scripts/sync.sh apply claude-md <repo>`",
    "ruleset_main": "`scripts/sync.sh apply ruleset <repo>` (after a green check)",
}
Row = tuple[str, str, str, str]  # check, repo, found, wanted


def cell(text: str) -> str:
    """Escape a table cell: `|` and line breaks."""
    return text.replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def items(detail: str) -> list[str]:
    """Detail split on `; `, consecutive duplicates collapsed as `item (x3)`, capped."""
    parts = [p for p in detail.split("; ") if p]
    out: list[str] = []
    i = 0
    while i < len(parts):
        j = i
        while j < len(parts) and parts[j] == parts[i]:
            j += 1
        out.append(cell(parts[i]) + (f" (x{j - i})" if j - i > 1 else ""))
        i = j
    if len(out) > MAX_ITEMS:
        out = [*out[:MAX_ITEMS], f"... and {len(out) - MAX_ITEMS} more"]
    return out


def found_wanted(check: str, detail: str) -> tuple[str, str]:
    """The found and wanted cells of a failing check."""
    parts = [p for p in detail.split("; ") if p]
    settings = [SETTING.fullmatch(p) for p in parts]
    if parts and all(settings):
        found = [f"{m[1]}: {m[2]}" for m in settings if m]
        want = [f"{m[1]}: {m[3]}" for m in settings if m]
        return "<br>".join(items("; ".join(found))), "<br>".join(items("; ".join(want)))
    return "<br>".join(items(detail)) or "-", cell(WANTED.get(check, "see docs/standard.md#audit"))


def status_of(c: dict[str, Any]) -> str:
    """The check status; older JSON has only `pass`."""
    return str(c.get("status") or ("pass" if c.get("pass") else "fail"))


def table(rows: list[Row], status: str, keep: int) -> list[str]:
    """A table of the first `keep` rows, with a line counting the rest."""
    lines = [HEADER]
    lines += [f"| {c} | {r} | {f} | {w} | {status} |" for c, r, f, w in rows[:keep]]
    if keep < len(rows):
        lines.append(f"\n... {len(rows) - keep} more rows in the audit artifact")
    return lines


def fix_for(check: str) -> str:
    """How to fix a check."""
    if check.startswith("tooling:"):
        return "see docs/tooling.md"
    if check.startswith("wf_"):
        return "by hand via PR: docs/standard.md#ci-hygiene"
    return FIX.get(check, "by hand, see docs/standard.md#audit")


def tooling(repos: list[tuple[str, dict[str, Any]]]) -> list[str]:
    """The collapsed tooling matrices, one per group."""
    out: list[str] = []
    for gid, title in GROUPS:
        cells = {
            n: {t: v for t, v in r["tooling"].items() if v.get("group") == gid} for n, r in repos if r.get("tooling")
        }
        cells = {n: c for n, c in cells.items() if any(v.get("status") != "n.a." for v in c.values())}
        if not cells:
            continue
        tools = sorted({t for c in cells.values() for t in c})
        out += [
            f"### {title}",
            "",
            "| repo | " + " | ".join(cell(t) for t in tools) + " |",
            "| --- |" + " --- |" * len(tools),
        ]
        for name in sorted(cells, key=str.lower):
            row = []
            for t in tools:
                v = cells[name].get(t)
                if v is None:
                    row.append("-")
                    continue
                prefix = {"warn": "warn: ", "fail": "FAIL: "}.get(str(v.get("severity")), "")
                row.append(cell(f"{prefix}{v.get('value') or '-'} ({v.get('status')})"))
            out.append(f"| {cell(name)} | " + " | ".join(row) + " |")
        out.append("")
    if not out:
        return []
    legend = (
        "Status: same = as expected, differs = not the expected value, absent = not present, "
        "n.a. = does not apply, unknown = could not be read. `warn:` = worth a look, `FAIL:` = drift (listed above)."
    )
    return ["<details><summary>Tooling inventory (informational)</summary>", "", legend, "", *out, "</details>"]


@dataclass
class Findings:
    """Rows of the Drift and Unknown tables, and the repos behind them."""

    drift: list[Row] = field(default_factory=list)
    unknown: list[Row] = field(default_factory=list)
    bad: set[str] = field(default_factory=set)
    blind: set[str] = field(default_factory=set)

    def add(self, status: str, row: Row) -> None:
        """File `row` as drift or unknown."""
        if status == "unknown":
            self.unknown.append(row)
            self.blind.add(row[1])
        else:
            self.drift.append(row)
            self.bad.add(row[1])


def collect(repos: list[tuple[str, dict[str, Any]]]) -> Findings:
    """Sort the failing checks and the failing tooling cells of every repo into drift and unknown rows."""
    found = Findings()
    for name, r in repos:
        for cid, c in r.get("checks", {}).items():
            st = status_of(c)
            if st == "fail":
                found.add(st, (cid, name, *found_wanted(cid, c.get("detail", ""))))
            elif st == "unknown":
                detail = "<br>".join(items(c.get("detail", ""))) or "-"
                found.add(st, (cid, name, detail, cell(WANTED.get(cid, "readable by the audit token"))))
        for tid, t in (r.get("tooling") or {}).items():
            if t.get("severity") == "fail" and t.get("status") in ("differs", "absent", "unknown"):
                row = (f"tooling:{tid}", name, cell(str(t.get("value") or "-")), cell(str(t.get("expected") or "-")))
                found.add(t["status"], row)
    found.drift.sort(key=lambda x: (x[0], x[1].lower()))
    found.unknown.sort(key=lambda x: (x[0], x[1].lower()))
    return found


def render(data: list[dict[str, Any]], head: str, *, with_tooling: bool, keep: int) -> str:
    """The issue body; `keep` caps the rows of both tables together (drift first)."""
    private = sorted((r for r in data if r.get("private")), key=lambda r: r["repo"])
    names: dict[str, str] = {str(r["repo"]): f"private repo {i}" for i, r in enumerate(private, 1)}
    repos = [(names.get(str(r["repo"]), str(r["repo"])), r) for r in data]
    f = collect(repos)
    ok = len(repos) - len(f.bad | f.blind)
    summary = f"{len(repos)} repos checked, {len(f.bad)} drifted, {len(f.blind)} with unknown checks, {ok} ok."
    lines = ["# Standard drift", "", head.replace("{summary}", summary)]
    if not f.drift and not f.unknown:
        lines += ["", "No drift: every repo matches the standard."]
    if f.drift:
        lines += ["", "## Drift", "", *table(f.drift, "drift", keep)]
    if f.unknown:
        lines += [
            "",
            "## Unknown (cannot read)",
            "",
            (
                "These are not drift: the audit token could not read them (for example HTTP 403). "
                "Widen the token's read scope (see docs/runbook-rollout.md#scheduled-audit)."
            ),
            "",
            *table(f.unknown, "unknown", max(keep - len(f.drift), 0)),
        ]
    if f.drift or f.unknown:
        ids = sorted({r[0] for r in f.drift + f.unknown})
        fixes = (f"| {cell(i)} | {fix_for(i)} |" for i in ids)
        lines += ["", "## How to fix", "", "| check | fix |", "| --- | --- |", *fixes]
    if with_tooling:
        tl = tooling(repos)
        if tl:
            lines += ["", "## Tooling", "", *tl]
    elif any(r.get("tooling") for _, r in repos):
        lines += ["", "## Tooling", "", "Omitted: the body is too large. See the tooling cells in the audit artifact."]
    return "\n".join(lines) + "\n"


def build(data: list[dict[str, Any]], date: str, run_url: str | None) -> str:
    """The body within the size limit: Tooling is dropped first, then table rows."""
    link = f" [Run]({run_url})." if run_url else ""
    head = f"Audit of {date}: {{summary}}{link}"
    total = sum(len(r.get("checks", {})) + len(r.get("tooling") or {}) for r in data)
    body = render(data, head, with_tooling=True, keep=total + 1)
    if len(body) <= MAX_BODY:
        return body
    # largest number of kept rows (drift first, then unknown) that fits, tooling dropped
    best = render(data, head, with_tooling=False, keep=0)
    lo, hi = 1, total
    while lo <= hi:
        mid = (lo + hi) // 2
        cand = render(data, head, with_tooling=False, keep=mid)
        if len(cand) <= MAX_BODY:
            best, lo = cand, mid + 1
        else:
            hi = mid - 1
    return best


def main() -> None:
    """Read the audit JSON on stdin, write the Markdown body on stdout."""
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--date", default=dt.datetime.now(dt.UTC).strftime("%Y-%m-%d"))
    p.add_argument("--run-url")
    a = p.parse_args()
    sys.stdout.write(build(json.load(sys.stdin), a.date, a.run_url))


if __name__ == "__main__":
    main()
