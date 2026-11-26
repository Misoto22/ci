"""Production code must not trap on data.

Counted per file, comments and string literals blanked: `try!`, `as!`, `fatalError(`, `preconditionFailure(`, and a force
unwrap of a call's or a subscript's result (`)!`, `]!`). Each file stays at or under the app's baseline, and the baseline
only falls: a file under its count fails until `--update` lowers it, so a cleanup is kept.
"""

import re

from .swift_source import strip_comments

NAME = "traps"
TRAP = re.compile(r"\btry!|\bas!|\bfatalError\(|\bpreconditionFailure\(|[)\]]!(?!=)")


def count(source: str) -> int:
    return len(TRAP.findall(strip_comments(source, strings=True)))
