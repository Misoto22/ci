import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from misoto_ios_checks.callback_isolation import problems


class CallbackIsolationTests(unittest.TestCase):
    def test_background_task_on_the_schedulers_queue_is_refused(self):
        source = "BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in }"
        self.assertEqual(len(problems(source)), 1)

    def test_background_task_on_the_main_queue_passes(self):
        for queue in (".main", "DispatchQueue.main"):
            source = f"BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: {queue}) {{ task in }}"
            self.assertEqual(problems(source), [], queue)

    def test_observer_on_the_posting_thread_is_refused(self):
        source = "center.addObserver(forName: .x, object: nil, queue: nil) { _ in }"
        self.assertEqual(len(problems(source)), 1)

    def test_observer_on_the_main_queue_passes(self):
        self.assertEqual(problems("center.addObserver(forName: .x, object: s, queue: .main) { _ in }"), [])

    def test_motion_query_reads_its_last_queue_argument(self):
        self.assertEqual(problems("m.queryActivityStarting(from: start, to: end, to: .main) { a, e in }"), [])
        self.assertEqual(len(problems("m.queryActivityStarting(from: start, to: end, to: queue) { a, e in }")), 1)

    def test_expiration_handler_must_be_sendable(self):
        self.assertEqual(len(problems("task.expirationHandler = { run.cancel() }")), 1)
        self.assertEqual(problems("task.expirationHandler = { @Sendable in completion.expire(cancelling: run) }"), [])

    def test_photo_progress_handler_inline_must_be_sendable(self):
        self.assertEqual(len(problems("options.progressHandler = { value, _, _, _ in }")), 1)
        self.assertEqual(problems("options.progressHandler = Self.progressHandler(progress)"), [])

    def test_limited_picker_completion_must_be_sendable(self):
        self.assertEqual(len(problems("lib.presentLimitedLibraryPicker(from: c) { [weak self] added in }")), 1)
        self.assertEqual(problems("lib.presentLimitedLibraryPicker(from: c) { @Sendable [weak self] added in }"), [])

    def test_comments_are_ignored(self):
        self.assertEqual(problems("// register(forTaskWithIdentifier: id, using: nil)"), [])


if __name__ == "__main__":
    unittest.main()
