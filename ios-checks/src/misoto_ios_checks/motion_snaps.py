"""Fails when a view or sheet change can land in one frame (motion snaps).

Detects five snap patterns in production Swift (comments and strings blanked):

- `animation-nil`: `.animation(nil`, `withAnimation(nil)`, `animation: nil`, `.animation = nil`
- `animation-ternary`: `.animation(cond ? nil : x)` or `.animation(cond ? x : nil)` where `cond` is not Reduce Motion alone
- `disables-animations`: `disablesAnimations = true`
- `perform-without-animation`: `performWithoutAnimation`
- `bare-swap`: an `if`/`else` over sheet state whose view branches carry no `.transition(`

Supports a per-file/per-kind ratchet baseline JSON (`{"files": {rel: {"reason": "...", "hits": {kind: count}}}}`)
that only falls on `--update`.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from .swift_source import strip_comments

NAME = "motion-snaps"

KINDS = {
    "animation-nil": re.compile(
        r"\.animation\(\s*nil\b|\bwithAnimation\(\s*nil\b|\banimation:\s*nil\b|\.animation\s*=\s*nil\b"
    ),
    "disables-animations": re.compile(r"\bdisablesAnimations\s*=\s*true\b"),
    "perform-without-animation": re.compile(r"\bperformWithoutAnimation\b"),
}

ADVICE = {
    "animation-nil": "a change with no animation lands in one frame; animate it with a motion token",
    "animation-ternary": "turning the animation off for one side snaps that side; keep one animation (Reduce Motion alone may turn it off)",
    "disables-animations": "a transaction that disables animations lands in one frame",
    "perform-without-animation": "UIView.performWithoutAnimation draws the change in one frame",
    "bare-swap": "an if/else on sheet state swaps two views in one frame; keep one view or add .transition",
}

ANIMATION_CALL = re.compile(r"\.animation\(")
DEFAULT_REDUCE_FLAGS = (
    "reduceMotion",
    "accessibilityReduceMotion",
    "Motion.reduced",
    "ReducedMotion.isEnabled",
    "UIAccessibility.isReduceMotionEnabled",
)
SHEET_STATE = re.compile(
    r"\b(?:expanded|isExpanded|atFull\w*|isFull\w*|atMiddle\w*|atMiddleHeight|folded|isFolded|lifted|lift|inSheet|"
    r"sheetHeight|sheetState|detent\w*|onMapGlass|standsOnGlass|atRest|risen)\b"
    r"|\bsheet\.(?:height|state|lift)\b|==\s*\.(?:full|middle|folded)\b"
)
IF_OPEN = re.compile(r"^\s*(?:\}\s*else\s+)?if\s+(?!let\b|var\b|case\b|#)(.+?)\s*\{\s*$")
IF_ONE_LINE = re.compile(r"^\s*if\s+(?!let\b|var\b|case\b|#)(.+?)\s*\{([^{}]+)\}\s*else\s*\{([^{}]+)\}\s*$")
SINGLE_VIEW = re.compile(r"^\s*(?:[A-Z]\w*\(.*\)|[a-z]\w*)(?:\s*\.(?!transition\()\w+\(.*\))*\s*$")
VIEW_LINE = re.compile(r"^\s*(?:[A-Z]\w*(?:\.\w+)*\s*[({]|\.\w+\()")


def _reduce_pattern(extra_flags: list[str] | None = None) -> re.Pattern[str]:
    names = [re.escape(name) for name in (*DEFAULT_REDUCE_FLAGS, *(extra_flags or []))]
    return re.compile(rf"^!?\(?\s*(?:{'|'.join(names)})\s*\)?$")


def _call_argument(code: str, start: int) -> str:
    depth, i = 0, start
    while i < len(code):
        if code[i] == "(":
            depth += 1
        elif code[i] == ")":
            depth -= 1
            if depth == 0:
                return code[start + 1 : i]
        i += 1
    return code[start + 1 :]


def _ternary_off(argument: str, reduce_re: re.Pattern[str]) -> bool:
    first = argument.split(",")[0] if "?" not in argument.split(",")[0] else argument
    match = re.match(r"^\s*(.+?)\s*\?\s*(.+?)\s*:\s*(.+?)\s*(?:,|$)", first, re.S)
    if not match:
        return False
    condition, yes, no = (part.strip() for part in match.groups())
    if "nil" not in (yes, no):
        return False
    return not reduce_re.match(condition)


def _block_end(lines: list[str], start: int, column: int = 0) -> int:
    depth, opened = 0, False
    for index in range(start, len(lines)):
        for char in lines[index][column if index == start else 0 :]:
            if char == "{":
                depth, opened = depth + 1, True
            elif char == "}" and opened:
                depth -= 1
                if depth == 0:
                    return index
    return len(lines) - 1


def _bare_swaps(lines: list[str]) -> list[int]:
    found = []
    for index, line in enumerate(lines):
        single = IF_ONE_LINE.match(line)
        if single and SHEET_STATE.search(single.group(1)):
            if all(SINGLE_VIEW.match(branch) for branch in single.group(2, 3)):
                found.append(index + 1)
            continue
        match = IF_OPEN.match(line)
        if not match or line.lstrip().startswith("}") or not SHEET_STATE.search(match.group(1)):
            continue
        end = _block_end(lines, index)
        if not re.match(r"^\s*\}\s*else\b", lines[end]):
            continue
        else_end = _block_end(lines, end, lines[end].index("else"))
        body = lines[index + 1 : else_end]
        if any(re.search(r"\breturn\b", part) for part in body):
            continue
        if not any(VIEW_LINE.match(part) for part in body):
            continue
        if any(".transition(" in part for part in body + [lines[else_end]] + lines[else_end + 1 : else_end + 3]):
            continue
        found.append(index + 1)
    return found


def hits(source: str, *, reduce_flags: list[str] | None = None) -> list[tuple[int, str]]:
    """Return `(line, kind)` pairs for every frame-snap hit in one Swift source string."""
    code = strip_comments(source, strings=True)
    lines = code.splitlines()
    reduce_re = _reduce_pattern(reduce_flags)
    found: list[tuple[int, str]] = []
    for number, line in enumerate(lines, start=1):
        for kind, pattern in KINDS.items():
            found += [(number, kind)] * len(pattern.findall(line))
    for match in ANIMATION_CALL.finditer(code):
        if _ternary_off(_call_argument(code, match.end() - 1), reduce_re):
            found.append((code.count("\n", 0, match.start()) + 1, "animation-ternary"))
    found += [(number, "bare-swap") for number in _bare_swaps(lines)]
    return sorted(found)


def counts(scanned: dict[str, list[tuple[int, str]]]) -> dict[str, dict[str, int]]:
    table: dict[str, dict[str, int]] = {}
    for rel, found in scanned.items():
        for _, kind in found:
            table.setdefault(rel, {}).setdefault(kind, 0)
            table[rel][kind] += 1
    return table


def compare(scanned: dict[str, list[tuple[int, str]]], baseline: dict) -> list[str]:
    now, failures = counts(scanned), []
    for rel in sorted(set(now) | set(baseline)):
        entry = baseline.get(rel, {})
        allowed = entry.get("hits", {})
        if rel in baseline and not str(entry.get("reason", "")).strip():
            failures.append(f"{rel}: the baseline gives no reason; say why its changes may land in one frame")
        for kind in sorted(set(now.get(rel, {})) | set(allowed)):
            have, may = now.get(rel, {}).get(kind, 0), allowed.get(kind, 0)
            if have > may:
                line_nums = ", ".join(str(n) for n, k in scanned.get(rel, []) if k == kind)
                failures.append(f"{rel}:{line_nums}: {kind} {have}, baseline {may}; {ADVICE[kind]}")
            elif have < may:
                failures.append(f"{rel}: {kind} {have}, baseline {may}; run --update to lower baseline")
    return failures


def update_baseline(scanned: dict[str, list[tuple[int, str]]], baseline_path: Path) -> list[str]:
    """Lower the baseline to match `scanned`; never raise or add entries."""
    baseline = json.loads(baseline_path.read_text(encoding="utf-8")).get("files", {}) if baseline_path.exists() else {}
    now, raised, lowered = counts(scanned), [], {}
    for rel, kinds in now.items():
        allowed = baseline.get(rel, {}).get("hits", {})
        raised += [f"{rel}: {kind} would raise the baseline" for kind, n in kinds.items() if n > allowed.get(kind, 0)]
    if raised:
        return raised
    for rel, entry in baseline.items():
        if rel in now:
            lowered[rel] = {"reason": entry.get("reason", ""), "hits": dict(sorted(now[rel].items()))}
    baseline_path.parent.mkdir(parents=True, exist_ok=True)
    baseline_path.write_text(
        json.dumps({"files": dict(sorted(lowered.items()))}, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return []
