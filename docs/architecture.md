# Architecture rules

## Package layering

```
GitData   →   Presenters   →   App
```

Each layer imports only the one to its left. Views never import `GitData` directly; they consume models through presenters.

| What | Where |
|---|---|
| Models, parsers, git readers, `GitBackend` protocol | `GitData` |
| UI-facing state, paging, selection, disk-change resilience | `Presenters` |
| View controllers, cells, layout, theme | `App/Views` |
| Composition root, wiring, window/repo lifecycle | `App/Coordinator` |

When adding a new data concept (a new git ref type, a new parsed field) it starts in `GitData/Models.swift` and `GitData/Parsing.swift`, gets exposed through `GitBackend`, forwarded through `GitService`, and surfaced via a presenter property — not accessed directly from a view.

## AppKit layout

**Schedule layout with `needsLayout = true`; never call `layoutSubtreeIfNeeded()` except inside `NSAnimationContext` blocks.**

`needsLayout` marks the view dirty and lets the run loop coalesce all pending changes into a single layout pass. `layoutSubtreeIfNeeded()` forces an immediate pass mid-call-stack, which creates feedback loops and fights the constraint engine. Consolidating layout logic in `layout()` / `viewDidLayout()` and triggering it via `needsLayout` keeps the flow unidirectional: *mutate state → mark dirty → AppKit calls `layout()` once*.

- Use `fittingSize` for measurement — it runs the constraint solver without committing frames.
- Set `preferredMaxLayoutWidth` explicitly from known geometry; don't rely on a layout pass having already run.
- Hook into content-change paths (`configure`, `presenterDidUpdate`) to mutate constraints and set `needsLayout = true`; let AppKit call `layout()` rather than driving it yourself.
- The one legitimate use of `layoutSubtreeIfNeeded()` is inside an `NSAnimationContext` block, where it is required to drive animated constraint changes.

## Extending `TimelineItem`

Adding a new `case` to `TimelineItem` requires wiring all four sites in `TimelineViewController`:

1. `tableView(_:viewFor:_:)` — return the right cell type
2. `tableView(_:heightOfRow:)` — return the right row height
3. `tableViewSelectionDidChange` — respond to selection (clear detail pane or open appropriate view)
4. `contextMenu(for:)` — provide right-click actions (or explicitly return `nil`)

Missing any one of them compiles cleanly but leaves the feature broken or crashy at runtime.

## Public API hygiene (Presenters package)

When replacing a typed property, remove its type declaration in the same commit. The `Presenters` package is consumed by the app target but orphaned `public enum`s are invisible to the compiler — they accumulate silently and mislead future readers about what state the presenter actually tracks.
