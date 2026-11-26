"""A system callback must run where its isolation holds.

Swift 6 opens every actor-isolated closure with an executor check. A closure written in a main-actor type (the `App`, a
view, an `@MainActor` model) is main-actor isolated, so when the system calls it on a queue of its own the check traps.
kioku-ios's daily background crash (TestFlight 1.15.2) was `BGTaskScheduler.register(..., using: nil)` in its `App`.
A registration whose queue the caller chooses must choose the main queue; a block the system calls on a queue it does not
name must open with `@Sendable` (or be built by a `nonisolated` function) and hop to the main actor itself.
"""

import re

from .swift_source import line_of, strip_comments

NAME = "callback-isolation"
MAIN = r"(?:\.main|DispatchQueue\.main|OperationQueue\.main)"

# (pattern that finds the call, pattern its queue argument must match, why)
RULES = [
    (
        re.compile(r"\bregister\(\s*forTaskWithIdentifier:[^,]*,\s*using:\s*([^)]*?)\s*\)"),
        re.compile(rf"^{MAIN}$"),
        "BGTaskScheduler.register must pass `using: .main`: on its own queue a main-actor handler traps",
    ),
    (
        re.compile(r"\baddObserver\(\s*forName:[^)]*?queue:\s*([A-Za-z.]+)"),
        re.compile(rf"^{MAIN}$"),
        "NotificationCenter.addObserver(forName:object:queue:) must pass the main queue: with `nil` the block runs on the"
        " posting thread",
    ),
    (
        re.compile(r"\bstartActivityUpdates\(\s*to:\s*([A-Za-z.()]+)"),
        re.compile(rf"^{MAIN}$"),
        "CMMotionActivityManager.startActivityUpdates must deliver to the main queue",
    ),
    (
        re.compile(r"\bqueryActivityStarting\(\s*from:[^,]*,\s*to:[^,]*,\s*to:\s*([^)\s,]+)"),
        re.compile(rf"^{MAIN}$"),
        "CMMotionActivityManager.queryActivityStarting must deliver to the main queue",
    ),
]

INLINE = [
    (
        re.compile(r"\.expirationHandler\s*=\s*\{"),
        "BGTask.expirationHandler must be `{ @Sendable in ... }`: BackgroundTasks names no queue for it",
    ),
    (
        re.compile(r"\.progressHandler\s*=\s*\{"),
        "PHImageRequestOptions.progressHandler runs on an arbitrary queue: open it with @Sendable or build it nonisolated",
    ),
    (
        re.compile(r"\bpresentLimitedLibraryPicker\(\s*from:[^()]*\)\s*\{"),
        "presentLimitedLibraryPicker's completion names no queue: open it with @Sendable and hop to the main actor",
    ),
]
SENDABLE = re.compile(r"\s*@Sendable\b")


def problems(source: str) -> list[tuple[int, str]]:
    code = strip_comments(source, strings=True)
    found = []
    for call, queue, why in RULES:
        for match in call.finditer(code):
            if not queue.match(match.group(1).strip()):
                found.append((line_of(code, match.start()), why))
    for opening, why in INLINE:
        for match in opening.finditer(code):
            if not SENDABLE.match(code, match.end()):
                found.append((line_of(code, match.start()), why))
    return sorted(found)
