"""Every animation takes the app's motion vocabulary.

An app names its curves in a few vocabulary files (`Motion.swift`, `RevalaMotion`, `DSMotion`, ...). Outside them:

- no curve of its own (`.easeInOut(...)`, `.spring(...)`, `.linear`, `.snappy`, `Animation.default`, ...), except in a file
  the app allows by name, with its reason;
- no `withAnimation` without an animation, which takes the system's default curve;
- no `.animation(_:)` modifier without `value:`, which animates every change of the view. The body form
  `.animation(_:) { ... }` and a transition's own `.opacity.animation(...)` are scoped, so they pass.

An app adopting the rule may keep a per-file baseline that only falls, as the trap check does.
"""

import re

from .swift_source import line_of, strip_comments

NAME = "motion"
CURVE = re.compile(
    r"(?:\bAnimation)?\.(?:easeIn|easeOut|easeInOut|linear|spring|interactiveSpring|interpolatingSpring|snappy|smooth"
    r"|bouncy|timingCurve)\b(?=\s*[(,)\n}]|\s*$)"
    r"|\bAnimation\.default\b"
)
BARE_WITH_ANIMATION = re.compile(r"\bwithAnimation\s*(?:\(\s*\))?\s*\{")
MODIFIER = re.compile(r"(?:(?<=[\s)}])|^)\.animation\(", re.M)


def _arguments(code: str, start: int) -> tuple[str, int]:
    """The text inside the parenthesis that opens just before `start`, and the index after its close."""
    depth, i = 1, start
    while i < len(code) and depth:
        if code[i] in "([{":
            depth += 1
        elif code[i] in ")]}":
            depth -= 1
        i += 1
    return code[start : i - 1], i


def problems(source: str, *, curves_allowed: bool = False) -> list[tuple[int, str]]:
    code = strip_comments(source, strings=True)
    found = []
    if not curves_allowed:
        for match in CURVE.finditer(code):
            found.append((line_of(code, match.start()), "a curve of its own; use the app's motion vocabulary"))
    for match in BARE_WITH_ANIMATION.finditer(code):
        found.append((line_of(code, match.start()), "withAnimation without an animation takes the default curve"))
    for match in MODIFIER.finditer(code):
        arguments, after = _arguments(code, match.end())
        if re.search(r"\bvalue\s*:", arguments) or re.match(r"\s*\{", code[after:]):
            continue
        found.append((line_of(code, match.start()), ".animation(_:) without value: animates every change of the view"))
    return sorted(found)
