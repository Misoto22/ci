# misoto-ios-checks

Swift source checks shared by the Misoto iOS apps (kioku-ios, revala-ios, kura-ios, jade). Standard-library Python,
so they run on Linux in seconds and the same way on a Mac.

| Check | Fails when |
|---|---|
| `scene-content` | a `WindowGroup`/`Window`/`DocumentGroup` content closure is not `@Sendable` (it traps on SwiftUI's render thread, iOS 27) |
| `callback-isolation` | `BGTaskScheduler.register` or `addObserver(forName:queue:)` is not on the main queue, or an inline `expirationHandler`, `progressHandler` or limited-library-picker completion is not `@Sendable` |
| `traps` | a file holds more `try!`, `as!`, `fatalError(`, `preconditionFailure(`, `)!` or `]!` than its baseline (which only falls) |
| `motion` | a curve outside the app's motion vocabulary, a bare `withAnimation { }`, or `.animation(_:)` without `value:` |
| `motion-snaps` | (opt-in) `animation(nil`, non-Reduce-Motion ternary nil animation, `disablesAnimations = true`, `performWithoutAnimation`, or bare sheet-state `if`/`else` swaps |
| `sheet-material` | (opt-in) `.presentationBackground(`, `.presentationDetents(`, or direct paper backgrounds outside the designated sheet-material owners |

## In an app

`ios-checks.toml` at the app root:

```toml
version = "0.12.0"                    # the Misoto22/ci tag to run
roots = ["Sources"]
exclude = ["Sources/**/Generated/*"]
checks = ["scene-content", "callback-isolation", "traps", "motion"]

[traps]
baseline = "scripts/trap-baseline.json"

[motion]
vocabulary = ["Sources/App/UI/Motion.swift"]
baseline = "scripts/motion-baseline.json"     # optional, while adopting the rule
[motion.allowed]
"Sources/App/UI/Skeleton.swift" = "the skeleton breath, a named DESIGN.md timing"
```

CI, in the app's workflow:

```yaml
  checks:
    uses: Misoto22/ci/.github/workflows/ios-checks.yml@<sha> # v0.12.0
```

Locally, `scripts/ios-checks.sh` (any arguments pass through, e.g. `--update` or `traps`):

```sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(python3 -c 'import tomllib; print(tomllib.load(open("ios-checks.toml", "rb"))["version"])')
exec uvx --from "git+https://github.com/Misoto22/ci@v${version}#subdirectory=ios-checks" misoto-ios-checks "$@"
```

To try an unreleased change, point at a local checkout: `uvx --from ~/code/personal/ci/ios-checks misoto-ios-checks`.

## Developing

    python3 -m unittest discover -s ios-checks/tests -t ios-checks
