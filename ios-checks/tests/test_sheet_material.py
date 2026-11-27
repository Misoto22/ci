import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from misoto_ios_checks import sheet_material


class SheetMaterialTests(unittest.TestCase):
    def test_flags_presentation_background_and_detents_outside_owners(self):
        source = """
        struct Sheet: View {
            var body: some View {
                content
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Color.paper)
            }
        }
        """
        found = sheet_material.problems(
            "Sources/Car/Sheet.swift",
            source,
            owners={"Sources/SheetMaterial.swift"},
            allowed_background=set(),
            allowed_detents=set(),
        )
        self.assertEqual(len(found), 2)
        self.assertEqual(
            sheet_material.problems(
                "Sources/SheetMaterial.swift",
                source,
                owners={"Sources/SheetMaterial.swift"},
                allowed_background=set(),
                allowed_detents=set(),
            ),
            [],
        )

    def test_flags_direct_paper_background_and_ui_paper_when_configured(self):
        source = """
        content
            .background(AppColor.bg)
            .surfaceMaterialSheet(detents: [.medium, .large])
        paper.backgroundColor = AppUIColor.bg
        """
        found = sheet_material.problems(
            "Sources/Map/Sheet.swift",
            source,
            owners=set(),
            allowed_background=set(),
            allowed_detents=set(),
            paper_colors=[r"AppColor\.bg"],
            ui_paper_colors=[r"AppUIColor\.bg"],
        )
        self.assertEqual(len(found), 2)

    def test_honours_allowed_background_and_detents(self):
        found = sheet_material.problems(
            "Sources/Flow.swift",
            ".presentationBackground(.clear)\n.presentationDetents([.large])\n",
            owners=set(),
            allowed_background={"Sources/Flow.swift"},
            allowed_detents={"Sources/Flow.swift"},
        )
        self.assertEqual(found, [])


if __name__ == "__main__":
    unittest.main()
