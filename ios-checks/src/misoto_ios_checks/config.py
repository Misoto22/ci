"""An app's `ios-checks.toml`: which checks run, over which sources, with which baselines.

    version = "0.12.0"                    # the Misoto22/ci tag the app runs; read by scripts and the reusable workflow
    roots = ["Sources"]                   # production Swift
    exclude = ["Sources/**/Generated/*"]  # globs on the root-relative path
    checks = ["scene-content", "callback-isolation", "traps", "motion"]

    [traps]
    baseline = "scripts/trap-baseline.json"

    [motion]
    vocabulary = ["Sources/App/UI/Motion.swift"]   # the files that define the app's curves
    baseline = "scripts/motion-baseline.json"       # optional ratchet for an app adopting the rule
    [motion.allowed]                                # a file that may keep one curve of its own, and why
    "Sources/App/UI/Skeleton.swift" = "the skeleton breath, a named DESIGN.md timing"
"""

import tomllib
from dataclasses import dataclass, field
from pathlib import Path

FILE = "ios-checks.toml"
DEFAULT_CHECKS = ["scene-content", "callback-isolation", "traps", "motion"]
ALL_CHECKS = [*DEFAULT_CHECKS, "motion-snaps", "sheet-material"]


@dataclass
class Config:
    root: Path
    version: str = ""
    roots: list[str] = field(default_factory=lambda: ["Sources"])
    exclude: list[str] = field(default_factory=list)
    checks: list[str] = field(default_factory=lambda: list(DEFAULT_CHECKS))
    traps_baseline: str = "scripts/trap-baseline.json"
    motion_vocabulary: list[str] = field(default_factory=list)
    motion_allowed: dict[str, str] = field(default_factory=dict)
    motion_baseline: str | None = None
    motion_snaps_baseline: str | None = None
    motion_snaps_reduce_flags: list[str] = field(default_factory=list)
    sheet_material_owners: list[str] = field(default_factory=list)
    sheet_material_adopts: str = r"surfaceMaterialSheet\(|servoSheetMaterial\(|(?:servo[Ff]|f)ittedSheet\(\)"
    sheet_material_allowed_background: dict[str, str] = field(default_factory=dict)
    sheet_material_allowed_detents: dict[str, str] = field(default_factory=dict)
    sheet_material_paper_colors: list[str] = field(default_factory=list)
    sheet_material_ui_paper_colors: list[str] = field(default_factory=list)


def load(root: Path) -> Config:
    path = root / FILE
    data = tomllib.loads(path.read_text()) if path.exists() else {}
    unknown = [name for name in data.get("checks", []) if name not in ALL_CHECKS]
    if unknown:
        raise SystemExit(f"{FILE}: unknown checks {unknown}; known: {ALL_CHECKS}")
    traps = data.get("traps", {})
    motion = data.get("motion", {})
    motion_snaps = data.get("motion_snaps", {})
    sheet_material = data.get("sheet_material", {})
    config = Config(root=root)
    config.version = data.get("version", "")
    config.roots = data.get("roots", config.roots)
    config.exclude = data.get("exclude", [])
    config.checks = data.get("checks", config.checks)
    config.traps_baseline = traps.get("baseline", config.traps_baseline)
    config.motion_vocabulary = motion.get("vocabulary", [])
    config.motion_allowed = motion.get("allowed", {})
    config.motion_baseline = motion.get("baseline")
    config.motion_snaps_baseline = motion_snaps.get("baseline")
    config.motion_snaps_reduce_flags = motion_snaps.get("reduce_flags", [])
    config.sheet_material_owners = sheet_material.get("owners", [])
    config.sheet_material_adopts = sheet_material.get("adopts", config.sheet_material_adopts)
    config.sheet_material_allowed_background = sheet_material.get("allowed_background", {})
    config.sheet_material_allowed_detents = sheet_material.get("allowed_detents", {})
    config.sheet_material_paper_colors = sheet_material.get("paper_colors", [])
    config.sheet_material_ui_paper_colors = sheet_material.get("ui_paper_colors", [])
    return config
