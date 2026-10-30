# Elemental

Local, offline, read-only macOS git client for reading and comprehending changes — not managing them.

## Architecture map

| Layer | Package / folder | Doc |
|---|---|---|
| Data | `Packages/GitData` | [data-layer.md](docs/data-layer.md) |
| Presenters | `Packages/Presenters` | [presenters.md](docs/presenters.md) |
| Views | `App/Views` | [view-layer.md](docs/view-layer.md) |
| Coordinator | `App/Coordinator` | [coordinator.md](docs/coordinator.md) |

Package rules, AppKit layout philosophy, and extension checklists: [architecture.md](docs/architecture.md)

Golden fixtures (UI stability tests, how to re-record): [golden-fixtures.md](docs/golden-fixtures.md)

Releasing, in-app updates (Sparkle) and signing keys: [releasing.md](docs/releasing.md)

Roadmap: [next.md](docs/next.md)

## Non-negotiables

- Read-only. No writes, no network, no LLM calls in the core path. (The opt-in, off-by-default updater is
  the one network exception; see releasing.md.)
- AppKit-first. No SwiftUI for load-bearing UI.
- All new parsers/readers go in `GitData`; all UI state lives in a presenter.

## Before pushing

CI (`.github/workflows/ci.yml`) builds the app with `xcodebuild`; the last three pushes to `main` failed it
before anyone noticed. Cloud sessions are Linux and cannot compile Swift or AppKit, so:

- Never push to `main`. Push a branch and open a PR; merge only once the CI `Tests` check is green on the head commit.
- After pushing, check the CI run (`actions_list`) or subscribe to the PR, and fix any red build before moving on.
- Where `xcodebuild` is available, build first: `set -o pipefail && xcodebuild build -workspace Elemental.xcworkspace -scheme Elemental -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO | xcbeautify`.
- Swift pitfall: in a `final class`, use the class name, not `Self`, inside `static let` initializers (newer Xcode rejects `Self` there).
