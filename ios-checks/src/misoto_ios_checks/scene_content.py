"""A scene's content closure must be `@Sendable`.

`WindowGroup { ... }` keeps its content closure in a view of SwiftUI's own, whose body SwiftUI may call on its asynchronous
render thread (iOS 27). Written in an `App`, the closure is inferred to the main actor, and Swift 6 opens it with an
isolation check that traps there in every build (`_dispatch_assert_queue_fail`; revala-ios, 2026-11-09). Build the content
in `body`, on the main actor, and hand it back: `WindowGroup { @Sendable in window }`.
"""

import re

from .swift_source import line_of, strip_comments

NAME = "scene-content"
SCENE = re.compile(
    r"\b(?:WindowGroup|DocumentGroup|ImmersiveSpace)\b"
    r"(?:\([^(){}]*(?:makeContent|content):\s*|\s*(?:\([^(){}]*\)\s*)?)\{"
    r"|(?<!->\s)\bWindow\([^(){}]*\)\s*\{"
)
SENDABLE = re.compile(r"\s*@Sendable\b")


def problems(source: str) -> list[tuple[int, str]]:
    code = strip_comments(source, strings=True)
    return [
        (line_of(code, match.start()), "a scene's content closure that is not @Sendable; build the view in body and hand it back")
        for match in SCENE.finditer(code)
        if not SENDABLE.match(code, match.end())
    ]
