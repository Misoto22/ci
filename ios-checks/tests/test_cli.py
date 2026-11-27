import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from misoto_ios_checks import cli, traps


def app(files: dict[str, str], toml: str = "", baselines: dict[str, dict] | None = None) -> tempfile.TemporaryDirectory:
    tmp = tempfile.TemporaryDirectory()
    root = Path(tmp.name)
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    if toml:
        (root / "ios-checks.toml").write_text(toml)
    for name, data in (baselines or {}).items():
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        (root / name).write_text(json.dumps(data))
    return tmp


def run(tmp, *argv) -> tuple[int, str]:
    out = io.StringIO()
    with redirect_stdout(out):
        code = cli.main(["--root", tmp.name, *argv])
    return code, out.getvalue()


class TrapCountTests(unittest.TestCase):
    def test_counts_each_trapping_construct(self):
        source = 'let a = try! f()\nlet b = x as! Int\nfatalError("no")\nlet c = g()!\nlet d = xs[0]!\n'
        self.assertEqual(traps.count(source), 5)

    def test_ignores_comments_strings_and_inequality(self):
        self.assertEqual(traps.count('// try! f()\nlet s = "as! x"\nif f() != g() {}\nlet ok = !flag\n'), 0)


class RunnerTests(unittest.TestCase):
    def test_a_clean_app_passes_every_check(self):
        tmp = app({"Sources/A.swift": "let window = W()\nWindowGroup { @Sendable in window }\n"})
        self.assertEqual(run(tmp)[0], 0)

    def test_a_crash_pattern_fails_and_names_the_line(self):
        tmp = app({"Sources/App.swift": "\nBGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { t in }"})
        code, out = run(tmp, "callback-isolation")
        self.assertEqual(code, 1)
        self.assertIn("Sources/App.swift:2:", out)

    def test_traps_ratchet_only_falls(self):
        tmp = app({"Sources/A.swift": "try! f()"}, baselines={"scripts/trap-baseline.json": {"Sources/A.swift": 1}})
        self.assertEqual(run(tmp, "traps")[0], 0)
        tmp = app({"Sources/A.swift": "try! f()\ntry! g()"}, baselines={"scripts/trap-baseline.json": {"Sources/A.swift": 1}})
        self.assertEqual(run(tmp, "traps")[0], 1)
        tmp = app({"Sources/A.swift": ""}, baselines={"scripts/trap-baseline.json": {"Sources/A.swift": 1}})
        self.assertEqual(run(tmp, "traps")[0], 1)
        self.assertEqual(run(tmp, "traps", "--update")[0], 0)
        self.assertEqual(json.loads((Path(tmp.name) / "scripts/trap-baseline.json").read_text()), {})

    def test_update_never_raises_or_adds(self):
        tmp = app(
            {"Sources/A.swift": "try! f()\ntry! g()", "Sources/B.swift": "try! h()"},
            baselines={"scripts/trap-baseline.json": {"Sources/A.swift": 1}},
        )
        run(tmp, "traps", "--update")
        self.assertEqual(json.loads((Path(tmp.name) / "scripts/trap-baseline.json").read_text()), {"Sources/A.swift": 1})

    def test_motion_skips_vocabulary_and_honours_allowed_files(self):
        toml = (
            'checks = ["motion"]\n[motion]\nvocabulary = ["Sources/Motion.swift"]\n'
            '[motion.allowed]\n"Sources/Skeleton.swift" = "the breath"\n'
        )
        tmp = app(
            {
                "Sources/Motion.swift": "static let quick = Animation.snappy(duration: 0.25)",
                "Sources/Skeleton.swift": ".easeInOut(duration: 1.1)",
                "Sources/Page.swift": "withAnimation(Motion.quick) { x = 1 }",
            },
            toml,
        )
        self.assertEqual(run(tmp)[0], 0)

    def test_motion_names_a_missing_allowed_file(self):
        toml = 'checks = ["motion"]\n[motion.allowed]\n"Sources/Gone.swift" = "x"\n'
        code, out = run(app({"Sources/A.swift": ""}, toml))
        self.assertEqual(code, 1)
        self.assertIn("Sources/Gone.swift", out)

    def test_motion_baseline_lets_an_app_adopt_the_rule(self):
        toml = 'checks = ["motion"]\n[motion]\nbaseline = "scripts/motion-baseline.json"\n'
        files = {"Sources/A.swift": "withAnimation(.easeIn) { x = 1 }"}
        tmp = app(files, toml, {"scripts/motion-baseline.json": {"Sources/A.swift": 1}})
        self.assertEqual(run(tmp)[0], 0)
        tmp = app(files, toml, {"scripts/motion-baseline.json": {}})
        self.assertEqual(run(tmp)[0], 1)

    def test_exclude_globs_skip_generated_files(self):
        toml = 'checks = ["traps"]\nexclude = ["Sources/Generated/*"]\n'
        self.assertEqual(run(app({"Sources/Generated/T.swift": "try! f()"}, toml))[0], 0)

    def test_version_prints_the_apps_pin(self):
        code, out = run(app({}, 'version = "0.12.0"\n'), "--version")
        self.assertEqual((code, out.strip()), (0, "0.12.0"))

    def test_motion_snaps_and_sheet_material_run_when_configured(self):
        toml = (
            'checks = ["motion-snaps", "sheet-material"]\n'
            '[sheet_material]\n'
            'owners = ["Sources/SheetMaterial.swift"]\n'
        )
        ok_files = {
            "Sources/SheetMaterial.swift": ".presentationDetents([.large])\n.presentationBackground(.clear)\n",
            "Sources/Page.swift": "content.surfaceMaterialSheet()\n",
        }
        self.assertEqual(run(app(ok_files, toml))[0], 0)
        bad_files = {
            "Sources/Bad.swift": ".presentationBackground(.red)\nwithAnimation(nil) { x = 1 }\n",
        }
        self.assertEqual(run(app(bad_files, toml))[0], 1)

    def test_an_unknown_check_in_the_config_is_refused(self):
        with self.assertRaises(SystemExit):
            run(app({}, 'checks = ["nope"]\n'))


if __name__ == "__main__":
    unittest.main()
