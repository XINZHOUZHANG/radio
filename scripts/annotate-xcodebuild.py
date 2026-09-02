#!/usr/bin/env python3
"""Expose useful xcodebuild diagnostics as GitHub check annotations."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


DIAGNOSTIC = re.compile(
    r"^(?P<file>.+?\.swift):(?P<line>\d+):(?P<column>\d+): "
    r"(?P<level>error|warning): (?P<message>.+)$"
)
GENERAL_ERROR = re.compile(r"^(?:xcodebuild: error:|Testing failed:|error:)\s*(?P<message>.+)$")


def escape(value: str) -> str:
    return (
        value.replace("%", "%25")
        .replace("\r", "%0D")
        .replace("\n", "%0A")
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: annotate-xcodebuild.py <xcodebuild.log>", file=sys.stderr)
        return 2

    workspace = Path(os.environ.get("GITHUB_WORKSPACE", Path.cwd())).resolve()
    seen: set[tuple[str, str, str, str]] = set()
    general_errors: set[str] = set()
    emitted = 0
    for raw_line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
        match = DIAGNOSTIC.match(raw_line.strip())
        if not match:
            general = GENERAL_ERROR.match(raw_line.strip())
            if general:
                general_errors.add(general.group("message"))
            continue
        values = match.groupdict()
        path = Path(values["file"])
        try:
            display_path = path.resolve().relative_to(workspace).as_posix()
        except ValueError:
            display_path = path.as_posix()
        key = (display_path, values["line"], values["column"], values["message"])
        if key in seen:
            continue
        seen.add(key)
        level = "error" if values["level"] == "error" else "warning"
        print(
            f"::{level} file={escape(display_path)},"
            f"line={values['line']},col={values['column']}::"
            f"{escape(values['message'])}"
        )
        emitted += 1
        if emitted >= 100:
            break

    for message in sorted(general_errors):
        print(f"::error::{escape(message)}")
        emitted += 1
    if emitted == 0:
        print("::error::xcodebuild failed without a parsed Swift compiler diagnostic")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
