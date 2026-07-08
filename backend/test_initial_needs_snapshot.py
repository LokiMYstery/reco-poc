import os
import sys
import tempfile
import unittest
from pathlib import Path


BACKEND_ROOT = Path(__file__).resolve().parent
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

_TEMP_DIR = tempfile.TemporaryDirectory()
os.environ["POC_SQLITE_PATH"] = str(Path(_TEMP_DIR.name) / "poc_test.db")
os.environ["POC_PREFERENCE_PATH"] = str(Path(_TEMP_DIR.name) / "poc_preference.json")

from poc_api import ContextPayload, _as_context_dict  # noqa: E402


def tearDownModule():
    _TEMP_DIR.cleanup()


class InitialNeedsSnapshotTests(unittest.TestCase):
    def normalize(self, **fields):
        return _as_context_dict(ContextPayload(**fields))

    def test_snapshot_decodes_mask_and_primary_need(self):
        context = self.normalize(
            questionnaire_snapshot={
                "schema_version": 1,
                "need_taxonomy_version": 1,
                "primary_need_bit": 2,
                "needs_mask": 6,
                "questionnaire_available": 1,
                "intent_available": 1,
            }
        )

        self.assertEqual(context["initial_need"], "睡眠/午休")
        self.assertEqual(context["initial_needs"], ["睡眠/午休", "放松/减压"])
        self.assertEqual(context["questionnaire_available"], 1)
        self.assertEqual(context["intent_available"], 1)

    def test_snapshot_mask_without_primary_falls_back_to_joined_initial_need(self):
        context = self.normalize(
            questionnaire_snapshot={
                "schema_version": 1,
                "need_taxonomy_version": 1,
                "needs_mask": 6,
            }
        )

        self.assertEqual(context["initial_needs"], ["睡眠/午休", "放松/减压"])
        self.assertEqual(context["initial_need"], "睡眠/午休、放松/减压")

    def test_legacy_initial_need_fields_keep_existing_behavior_without_snapshot(self):
        explicit_primary = self.normalize(
            initial_need="学习/工作专注",
            initial_needs=["睡眠/午休", "放松/减压"],
        )
        self.assertEqual(explicit_primary["initial_need"], "学习/工作专注")
        self.assertEqual(explicit_primary["initial_needs"], ["睡眠/午休", "放松/减压"])

        needs_only = self.normalize(initial_needs=["睡眠/午休", "放松/减压"])
        self.assertEqual(needs_only["initial_need"], "睡眠/午休、放松/减压")

    def test_zero_mask_does_not_produce_initial_need_fields(self):
        context = self.normalize(
            initial_need="学习/工作专注",
            initial_needs=["睡眠/午休"],
            questionnaire_snapshot={
                "schema_version": 1,
                "need_taxonomy_version": 1,
                "needs_mask": 0,
            },
        )

        self.assertNotIn("initial_need", context)
        self.assertNotIn("initial_needs", context)

    def test_invalid_snapshot_values_are_ignored_without_error(self):
        unknown_version = self.normalize(
            initial_need="阅读陪伴",
            questionnaire_snapshot={
                "schema_version": 1,
                "need_taxonomy_version": 99,
                "primary_need_bit": 2,
                "needs_mask": 6,
            },
        )
        self.assertEqual(unknown_version["initial_need"], "阅读陪伴")

        invalid_values = self.normalize(
            questionnaire_snapshot={
                "schema_version": 1,
                "need_taxonomy_version": 1,
                "primary_need_bit": 3,
                "needs_mask": "not-an-int",
            },
        )
        self.assertNotIn("initial_need", invalid_values)
        self.assertNotIn("initial_needs", invalid_values)

        unknown_bit = self.normalize(
            questionnaire_snapshot={
                "schema_version": 1,
                "need_taxonomy_version": 1,
                "needs_mask": (1 << 9) | 2,
            },
        )
        self.assertEqual(unknown_bit["initial_needs"], ["睡眠/午休"])
        self.assertEqual(unknown_bit["initial_need"], "睡眠/午休")


if __name__ == "__main__":
    unittest.main()
