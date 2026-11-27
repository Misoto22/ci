"""Fails when a sheet sets its own presentation background, detents, or paper outside the designated owners.

Configured in `ios-checks.toml` under `[sheet_material]`:

    [sheet_material]
    owners = ["Sources/Components/SheetMaterial.swift", "Sources/Components/SheetMaterialModifier.swift"]
    adopts = "servoSheetMaterial\\(|surfaceMaterialSheet\\(|(?:servo[Ff]|f)ittedSheet\\(\\)"
    paper_colors = ["RevalaColor\\.bg", "RevalaColor\\.groupedBg"]
    ui_paper_colors = ["RevalaUIColor\\.bg"]
    [sheet_material.allowed_background]
    "Sources/Onboarding/OnboardingFlow.swift" = "full-screen clear cover"
    [sheet_material.allowed_detents]
    "Sources/Car/InviteSheet.swift" = "system share sheet"
"""

from __future__ import annotations

import re

from .swift_source import strip_comments

NAME = "sheet-material"

DEFAULT_ADOPTS = r"surfaceMaterialSheet\(|servoSheetMaterial\(|(?:servo[Ff]|f)ittedSheet\(\)"
PRESENTATION_BACKGROUND = re.compile(r"\.presentationBackground\(")
PRESENTATION_DETENTS = re.compile(r"\.presentationDetents\(")


def problems(
    rel: str,
    source: str,
    *,
    owners: set[str],
    allowed_background: set[str],
    allowed_detents: set[str],
    adopts_pattern: str = DEFAULT_ADOPTS,
    paper_colors: list[str] | None = None,
    ui_paper_colors: list[str] | None = None,
) -> list[tuple[int, str]]:
    """Return `(line, message)` pairs for sheet-material violations in one file."""
    if rel in owners:
        return []
    code = strip_comments(source, strings=True)
    adopts = bool(re.compile(adopts_pattern).search(code))

    hand_switch_re = None
    hand_bg_re = None
    if paper_colors:
        joined = "|".join(paper_colors)
        hand_switch_re = re.compile(rf"(?:Color)?\.clear\s*:\s*(?:{joined})\b|(?:{joined})\s*:\s*(?:Color)?\.clear\b")
        hand_bg_re = re.compile(rf"^\s*\.background\((?:{joined})\)\s*$")

    ui_paper_re = None
    if ui_paper_colors:
        joined_ui = "|".join(ui_paper_colors)
        ui_paper_re = re.compile(rf"backgroundColor\s*=\s*(?:{joined_ui})\b")

    found: list[tuple[int, str]] = []
    for number, line in enumerate(code.splitlines(), start=1):
        if PRESENTATION_BACKGROUND.search(line) and rel not in allowed_background:
            found.append((number, ".presentationBackground outside sheet material owner"))
        if PRESENTATION_DETENTS.search(line) and rel not in allowed_detents:
            found.append((number, ".presentationDetents outside sheet material owner"))
        if hand_switch_re and hand_switch_re.search(line):
            found.append((number, "hand-made glass-or-paper switch; use the shared sheet material"))
        if adopts and hand_bg_re and hand_bg_re.match(line):
            found.append((number, "sheet content paints paper directly; let the sheet material show through"))
        if ui_paper_re and ui_paper_re.search(line):
            found.append((number, "UIKit paper background outside sheet material owner"))
    return found
