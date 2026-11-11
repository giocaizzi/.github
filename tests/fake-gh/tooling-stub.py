# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""A stand-in for scripts/tooling.py in scripts/test-sync.sh (sync.sh `TOOLING=` override).

`wanted` prints the stdin paths that end in `.tool`. `collect ... <dir>` prints one cell per STUB_MODE:
info (default), fail (severity fail, differs), warn, crash (exit 3), garbage (not JSON). The `files` cell holds the
fetched `.tool` files and the `unreadable` cell the contents of <dir>/.audit/unreadable, both comma-joined.
"""

import json
import os
import pathlib
import sys


def main() -> int:
    mode = os.environ.get("STUB_MODE", "info")
    if sys.argv[1] == "wanted":
        for line in sys.stdin.read().splitlines():
            if line.endswith((".tool", ".forbidden")):
                print(line)
        return 0
    if mode == "crash":
        return 3
    if mode == "garbage":
        print("not json")
        return 0
    root = pathlib.Path(sys.argv[-1])
    unreadable = root / ".audit" / "unreadable"
    fetched = sorted(str(p.relative_to(root)) for p in root.rglob("*.tool"))
    severity = {"fail": "fail", "warn": "warn"}.get(mode, "info")
    cells = {
        "tool_a": {
            "group": "g",
            "value": "1",
            "expected": "2",
            "status": "differs",
            "severity": severity,
        },
        "files": {
            "group": "g",
            "value": ",".join(fetched),
            "expected": None,
            "status": "same",
            "severity": "info",
        },
        "unreadable": {
            "group": "g",
            "value": ",".join(unreadable.read_text().split()) if unreadable.exists() else "",
            "expected": None,
            "status": "same",
            "severity": "info",
        },
    }
    print(json.dumps(cells))
    return 0


if __name__ == "__main__":
    sys.exit(main())
