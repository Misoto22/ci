"""Swift source with its comments and string literals blanked, and the production files a check reads.

Blanking keeps every newline, so a match's line number in the result is its line in the file.
"""

from fnmatch import fnmatch
from pathlib import Path


def strip_comments(source: str, *, strings: bool = False) -> str:
    """Blanks `//` and nested `/* */` comments, and string literals too when `strings` is set, keeping newlines."""
    out = []
    i, n = 0, len(source)
    depth = 0
    while i < n:
        c = source[i]
        two = source[i : i + 2]
        if depth:
            if two == "/*":
                depth += 1
                out.append("  ")
                i += 2
            elif two == "*/":
                depth -= 1
                out.append("  ")
                i += 2
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
            continue
        if two == "//":
            while i < n and source[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if two == "/*":
            depth = 1
            out.append("  ")
            i += 2
            continue
        if c == '"':
            quote = '"""' if source.startswith('"""', i) else '"'
            out.append(quote)
            i += len(quote)
            while i < n and not source.startswith(quote, i):
                if source[i] == "\\" and i + 1 < n:
                    out.append("  " if strings else source[i : i + 2])
                    i += 2
                    continue
                out.append("\n" if source[i] == "\n" else (" " if strings else source[i]))
                i += 1
            out.append(quote)
            i += len(quote)
            continue
        out.append(c)
        i += 1
    return "".join(out)


def line_of(code: str, index: int) -> int:
    return code.count("\n", 0, index) + 1


def swift_files(root: Path, roots: list[str], exclude: list[str]) -> list[Path]:
    """Every Swift file under the production roots, minus the excluded globs (matched on the root-relative path)."""
    found = []
    for top in roots:
        for path in sorted((root / top).rglob("*.swift")):
            relative = path.relative_to(root).as_posix()
            if not any(fnmatch(relative, pattern) for pattern in exclude):
                found.append(path)
    return found
