import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from misoto_ios_checks.motion import problems


class MotionTests(unittest.TestCase):
    def test_a_curve_of_its_own_is_refused(self):
        self.assertEqual(len(problems("withAnimation(.easeInOut(duration: 0.3)) { open = true }")), 1)
        self.assertEqual(len(problems(".animation(.spring(response: 0.4), value: x)")), 1)
        self.assertEqual(len(problems(".animation(.linear, value: x)")), 1)
        self.assertEqual(len(problems("let a = Animation.default")), 1)

    def test_motion_tokens_pass(self):
        self.assertEqual(problems("withAnimation(Motion.panel) { open = true }"), [])
        self.assertEqual(problems(".animation(Motion.quick, value: selection)"), [])
        self.assertEqual(problems(".animation(animated ? Motion.quick.delay(0.9) : nil, value: drawn)"), [])

    def test_with_animation_without_an_animation_is_refused(self):
        self.assertEqual(len(problems("withAnimation { open.toggle() }")), 1)
        self.assertEqual(len(problems("withAnimation() { open.toggle() }")), 1)

    def test_animation_modifier_without_value_is_refused(self):
        self.assertEqual(len(problems("Text(x)\n    .animation(Motion.panel)")), 1)

    def test_scoped_animation_forms_pass(self):
        self.assertEqual(problems(".animation(Motion.panel) { $0.opacity(isActive ? 1 : 0) }"), [])
        self.assertEqual(problems(".transition(.opacity.animation(Motion.quick))"), [])
        self.assertEqual(problems("TimelineView(.animation(minimumInterval: nil)) { t in }"), [])

    def test_names_that_only_look_like_curves_pass(self):
        self.assertEqual(problems("LinearGradient(colors: c, startPoint: .top, endPoint: .bottom)"), [])
        self.assertEqual(problems(".scrollTargetBehavior(.viewAligned)\nlet smoothed = values.smoothedLine"), [])

    def test_an_allowed_file_keeps_its_curve_but_not_the_other_rules(self):
        self.assertEqual(problems(".easeInOut(duration: KiokuSkeleton.breath)", curves_allowed=True), [])
        self.assertEqual(len(problems("withAnimation { x = 1 }", curves_allowed=True)), 1)

    def test_comments_and_strings_are_ignored(self):
        self.assertEqual(problems('// withAnimation { x }\nlet s = ".easeIn(duration: 1)"'), [])


if __name__ == "__main__":
    unittest.main()
