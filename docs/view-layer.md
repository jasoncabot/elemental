# Feature: View Layer (AppKit)

> All on-screen UI. AppKit-first, traditional. Binds to presenters via their observation interface and
> has **zero git knowledge**. See [ORCHESTRATOR.md](ORCHESTRATOR.md) and
> [presenters.md](presenters.md).

## Purpose

Render the SourceTree/Fork-like UI with native, high-performance controls, optimized for **reading
diffs**. The two pieces that must be excellent (and are why we chose AppKit over SwiftUI) are the
**virtualized commit list + graph** and the **diff renderer**.

## Window layout

`NSSplitView` (3 panes), owned by the coordinator's window controller:

1. **Sidebar** — `NSOutlineView`: open repositories with their branches/tags/remotes/worktrees.
   Accepts **drag-in of folder URLs** (start viewing a project) and **drag-out** to remove. Drag/drop
   wiring routes to the coordinator's bookmark store; selection drives `SidebarPresenter`.
2. **Commit list** — `NSTableView` (view-based, cell reuse) bound to `TimelinePresenter`. Columns:
   **graph**, author, date, subject. Virtualized for large logs. Keyboard nav (j/k + arrows), load-more
   on scroll-to-bottom. A non-modal **dirty banner** (NSView strip) appears here when
   `presenter.isDirty`, with a **Refresh** button routing to the presenter.
3. **Detail** — commit metadata header + **diff view**, bound to `CommitDetailPresenter`. A separate
   **working-copy view** (bound to `WorkingCopyPresenter`) shows staged/unstaged file lists with their
   diffs.

## Commit-graph cell

- A **custom `NSView`** used as the graph column's cell. Computes nothing itself — it draws a
  precomputed **lane layout** supplied by the presenter/timeline (lanes derived from each commit's
  `parents`).
- **Lane algorithm** (incremental "railroad"): maintain active lanes as you walk commits newest→oldest;
  assign each commit a column; route parent edges into existing/new lanes; handle merges (multiple
  parents fan-in) and branches (fan-out). Output per row: node column, and the set of edges crossing
  that row with colors. Keep it O(active lanes) per row.
- Draw with CoreGraphics (CALayer-backed view), reusing cells; colors stable per lane.

## Diff view (read-only, high-performance)

- **TextKit 2 / CoreText**-based custom view (not stock `NSTextView`) so large files and big diffs stay
  fast and fully controllable.
- Features: monospaced rendering, **line-number gutters** (old/new), per-line add/remove/context
  coloring, **intra-line word-diff** highlighting, fast selection + copy. **Unified** mode first,
  **side-by-side** later. Read-only — no editing affordances.
- Binary/large-file guard: show a placeholder ("binary file" / "large diff — N lines") instead of
  rendering.

## Binding

- Each view controller holds its presenter and conforms to `PresenterObserving`; on
  `presenterDidUpdate` it reloads the relevant control (or applies a diff to avoid full reloads on the
  table). No data-layer types appear here.
- User actions (selection, Refresh, drag/drop, load-more) call presenter/coordinator methods; views
  never call git.

## Non-goals

- No SwiftUI for load-bearing UI (an optional `NSHostingView` island for a trivial settings pane is
  discretionary, not required).
- No git invocation, no business logic, no write/edit UI in v1.

## Verification

- Manual: large repo (50k+ commits) scrolls smoothly; graph stays aligned with rows; large-file diff
  renders without freeze; selection/copy works.
- Snapshot/layout tests for the graph cell against known parent topologies (straight line, branch,
  merge, octopus).
- Dirty banner appears on `isDirty` and Refresh button routes correctly (with a fake presenter).
