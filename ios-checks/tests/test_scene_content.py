import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from misoto_ios_checks.scene_content import problems


class SceneContentTests(unittest.TestCase):
    def test_main_actor_window_group_closure_is_refused(self):
        self.assertEqual(len(problems("var body: some Scene {\n    WindowGroup {\n        ContentView()\n    }\n}")), 1)

    def test_sendable_closure_handing_back_a_built_view_passes(self):
        self.assertEqual(problems("let window = KiokuWindow()\nWindowGroup { @Sendable in window }"), [])

    def test_titled_window_scene_is_checked(self):
        self.assertEqual(len(problems('Window("Log", id: "log") { LogView() }')), 1)

    def test_a_type_named_window_is_not_a_scene(self):
        self.assertEqual(problems("func plan() -> Window {\n    Window(items: [])\n}"), [])

    def test_comments_and_strings_are_ignored(self):
        self.assertEqual(problems('// WindowGroup { x }\nlet s = "WindowGroup { y }"'), [])

    def test_reports_the_line(self):
        self.assertEqual(problems("\n\nWindowGroup {\n}")[0][0], 3)


if __name__ == "__main__":
    unittest.main()
