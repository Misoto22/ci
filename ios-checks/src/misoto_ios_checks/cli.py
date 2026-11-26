"""Runs an app's configured checks over its production Swift.

    misoto-ios-checks                      # every check ios-checks.toml lists, from the current directory
    misoto-ios-checks traps motion         # only these
    misoto-ios-checks --root path/to/app
    misoto-ios-checks --update             # lower the traps and motion baselines to today's counts (never raises one)
    misoto-ios-checks --version            # the version ios-checks.toml pins (for scripts and the reusable workflow)

Exit status 1 when any check fails. Standard library only.
"""

import argparse
import json
import sys
from pathlib import Path

from . import __version__, callback_isolation, config, motion, scene_content, traps
from .swift_source import swift_files


def _files(cfg: config.Config) -> list[tuple[str, str]]:
    return [(path.relative_to(cfg.root).as_posix(), path.read_text()) for path in swift_files(cfg.root, cfg.roots, cfg.exclude)]


def _ratchet(label: str, now: dict[str, int], baseline_path: Path | None, update: bool, root: Path) -> list[str]:
    """Each file's count stays at or under its baseline, and a baseline under today's count is stale."""
    if baseline_path is None:
        return [f"{path}: {n} {label}" for path, n in sorted(now.items())]
    full = root / baseline_path
    baseline = json.loads(full.read_text()) if full.exists() else {}
    if update:
        lowered = {path: min(n, baseline[path]) for path, n in now.items() if path in baseline}
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_text(json.dumps(dict(sorted(lowered.items())), indent=2) + "\n")
        return []
    failures = []
    for path, n in sorted(now.items()):
        if n > baseline.get(path, 0):
            failures.append(f"{path}: {n} {label}, baseline {baseline.get(path, 0)}")
    for path, allowed in sorted(baseline.items()):
        if now.get(path, 0) < allowed:
            failures.append(f"{path}: {now.get(path, 0)} {label}, under baseline {allowed}; run --update to keep the cleanup")
    return failures


def run(cfg: config.Config, names: list[str], update: bool = False) -> int:
    files = _files(cfg)
    status = 0
    for name in names:
        if name == scene_content.NAME:
            failures = [f"{p}:{n}: {why}" for p, text in files for n, why in scene_content.problems(text)]
        elif name == callback_isolation.NAME:
            failures = [f"{p}:{n}: {why}" for p, text in files for n, why in callback_isolation.problems(text)]
        elif name == traps.NAME:
            now = {p: c for p, text in files if (c := traps.count(text))}
            failures = _ratchet("trapping constructs", now, Path(cfg.traps_baseline), update, cfg.root)
        elif name == motion.NAME:
            vocabulary = set(cfg.motion_vocabulary)
            found = {
                p: motion.problems(text, curves_allowed=p in cfg.motion_allowed)
                for p, text in files
                if p not in vocabulary
            }
            if cfg.motion_baseline:
                now = {p: len(f) for p, f in found.items() if f}
                failures = _ratchet("motion findings", now, Path(cfg.motion_baseline), update, cfg.root)
            else:
                failures = [f"{p}:{n}: {why}" for p, f in sorted(found.items()) for n, why in f]
            missing = [p for p in list(cfg.motion_allowed) + cfg.motion_vocabulary if not (cfg.root / p).is_file()]
            failures += [f"{p}: named in ios-checks.toml [motion] but not found" for p in missing]
        else:
            raise SystemExit(f"unknown check {name}")
        if failures:
            status = 1
            print(f"{name}: failed")
            print("\n".join(f"  {line}" for line in failures))
        else:
            print(f"{name}: ok")
    return status


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="misoto-ios-checks", description=__doc__.splitlines()[0])
    parser.add_argument("checks", nargs="*", help="checks to run (default: those ios-checks.toml lists)")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--update", action="store_true", help="lower the baselines to today's counts")
    parser.add_argument("--version", action="store_true", help="print the version ios-checks.toml pins")
    args = parser.parse_args(argv)
    cfg = config.load(args.root.resolve())
    if args.version:
        print(cfg.version or __version__)
        return 0
    names = args.checks or cfg.checks
    unknown = [n for n in names if n not in config.ALL_CHECKS]
    if unknown:
        parser.error(f"unknown checks {unknown}; known: {config.ALL_CHECKS}")
    return run(cfg, names, update=args.update)


if __name__ == "__main__":
    sys.exit(main())
