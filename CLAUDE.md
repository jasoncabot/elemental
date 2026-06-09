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

Roadmap: [next.md](docs/next.md)

## Non-negotiables

- Read-only. No writes, no network, no LLM calls in the core path.
- AppKit-first. No SwiftUI for load-bearing UI.
- All new parsers/readers go in `GitData`; all UI state lives in a presenter.
