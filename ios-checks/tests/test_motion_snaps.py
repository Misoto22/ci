import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from misoto_ios_checks import motion_snaps


TERNARY = """
struct Head: View {
    var body: some View {
        name
            .opacity(expanded ? 1 : 0)
            .animation(expanded ? nil : Motion.quick, value: expanded)
    }
}
"""

REDUCE_ONLY = """
        dial.animation(reduceMotion ? nil : Motion.standard, value: fill)
"""

NIL_FORMS = """
        a.animation(nil, value: x)
        withAnimation(nil) { controlsTop = top }
        withTransaction(Transaction(animation: nil)) { x = 1 }
        b.transaction { $0.animation = nil }
        var t = Transaction()
        t.disablesAnimations = true
        UIView.performWithoutAnimation { surface.effect = glass }
"""

SWAP = """
struct Foot: View {
    var body: some View {
        if folded {
            GlassBar()
        } else {
            CheapestCard()
                .padding(.top, 4)
        }
    }
}
"""

SWAP_WITH_TRANSITION = """
struct Foot: View {
    var body: some View {
        if folded {
            GlassBar().transition(.opacity)
        } else {
            CheapestCard().transition(.opacity)
        }
    }
}
"""


class MotionSnapsTests(unittest.TestCase):
    def test_ternary_and_nil_forms_are_flagged(self):
        self.assertEqual(motion_snaps.hits(TERNARY), [(6, "animation-ternary")])
        self.assertEqual(motion_snaps.hits(REDUCE_ONLY), [])
        kinds = [kind for _, kind in motion_snaps.hits(NIL_FORMS)]
        self.assertEqual(
            kinds,
            [
                "animation-nil",
                "animation-nil",
                "animation-nil",
                "animation-nil",
                "disables-animations",
                "perform-without-animation",
            ],
        )

    def test_bare_swap_requires_transition(self):
        self.assertEqual(motion_snaps.hits(SWAP), [(4, "bare-swap")])
        self.assertEqual(motion_snaps.hits(SWAP_WITH_TRANSITION), [])

    def test_baseline_ratchet_only_lowers(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "baseline.json"
            path.write_text(
                json.dumps({"files": {"Sources/A.swift": {"reason": "existing", "hits": {"animation-nil": 2}}}})
            )
            self.assertNotEqual(motion_snaps.update_baseline({"Sources/A.swift": [(1, "animation-nil"), (2, "animation-nil"), (3, "animation-nil")]}, path), [])
            self.assertEqual(motion_snaps.update_baseline({"Sources/A.swift": [(1, "animation-nil")]}, path), [])
            updated = json.loads(path.read_text())["files"]
            self.assertEqual(updated["Sources/A.swift"]["hits"]["animation-nil"], 1)


if __name__ == "__main__":
    unittest.main()
