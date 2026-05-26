# Elemental — Orchestrator (Project Manager)

> Read this first. It is the single source of truth for how the pieces fit together, who depends on
> whom, and the contracts each feature must honor. Each feature is implementable independently by a
> separate agent against the contracts named here.

## What we're building

A fully native, open-source **macOS app for reviewing git commits locally**. Diff-viewing-optimized,
**mostly read-only** (no history rewriting). Primary view: a timeline of commits per repo plus the
working copy's staged/unstaged changes. SourceTree/Fork-like layout: a sidebar of repo "folders" you
drag in, with commits listed per repo.

### Fixed decisions (do not relitigate)
- **Data source:** the **user's own `git`** binary via plumbing/porcelain. Not libgit2, not
  hand-parsing `.git`. This is what gives **forward-compatibility with modern/upcoming git features**
  (worktrees today; reftable, partial/sparse clone, SHA-256, fsmonitor, future formats) for free.
- **Distribution:** non-MAS, **Developer ID notarized** (DMG). No App Sandbox → can exec system git,
  full `.gitconfig` fidelity, watch any `.git`, follow worktrees/submodules with no silent failures.
- **Min OS:** macOS 15 (Sequoia).
- **UI:** **AppKit-first**, traditional `NSWindowController`/`NSViewController`. No load-bearing
  SwiftUI.

## Core principle: SHA is identity, refs are a view

Existing tools break on disk changes because they treat **refs** as stable identity. Git objects are
content-addressed and immutable by SHA, so a loaded commit/diff stays valid regardless of branch
switches, squashes, or rebases done in the CLI. Therefore:

- All model state is **keyed by SHA**, never by ref name.
- Refs (branches/tags/HEAD) are a **mutable projection** refreshed separately.
- On disk change we **do not auto-reload** — we surface a "data changed → Refresh" banner and keep the
  current SHA-keyed views rendered until the user acks.

This is the headline resilience feature and it falls out of the data model, not bolted-on patches.

## Architecture & layering

```
coordinator  ── owns app shell, windows, navigation wiring, repo bookmark store
    │ creates & connects
presenters   ── main-actor view-models; UI state, selection, paging, dirty/Refresh reconciliation
    │ consumes (protocols + models)
data layer   ── GitBackend protocol → CLIGitBackend (Process→git); GitService actor; RepoWatcher
    │ drives
view layer   ── AppKit views; bind to presenters via thin observation; zero git knowledge
```

Dependencies point **inward toward the data layer**. The view layer never imports git types directly;
it talks to presenters. Presenters never spawn processes; they call the data layer's async API.

## Feature docs & ownership

| Doc | Owns | Depends on |
|-----|------|------------|
| [data-layer.md](data-layer.md) | `GitBackend`, `CLIGitBackend`, `GitService`, models, `RepoWatcher` | nothing (foundation) |
| [presenters.md](presenters.md) | per-pane view-models, dirty/Refresh logic | data-layer protocols + models |
| [view-layer.md](view-layer.md) | AppKit views, commit-graph cell, diff view | presenters' observation API |
| [coordinator.md](coordinator.md) | app shell, window controller, navigation, bookmark store | presenters + view layer |
| [qa-tester.md](qa-tester.md) | test strategy, shared `FixtureRepo`, snapshots, fuzzing, mutation testing | all seams (cross-cutting) |

## Shared contracts (the seams agents build against)

These must be agreed before parallel work; they live in the **data layer** doc and are imported by
presenters. Names are normative.

- **Models (immutable value types):** `Commit` (sha, parents, author, committer, dates, subject, body,
  refNames), `DiffFile`, `DiffHunk`, `DiffLine`, `RefSnapshot` (branches/tags/remotes/HEAD →
  SHA map), `WorkingCopyStatus`, `Repository` (root URL, gitDir, commonDir, worktrees).
- **Data API (async, actor-backed):** `GitBackend` protocol — `openRepository(at:)`,
  `loadCommits(_ query:)` (paged/streamed), `refs(for:)`, `diff(for sha:)`, `diff(range:)`,
  `workingCopyStatus(for:)`, `blob(at path:rev:)`. All cancellable.
- **Watcher:** `RepoWatcher` emits an async stream of `dirty` events keyed by repository.
- **Presenter→view binding:** a minimal observation interface (closure/delegate or `@Observable`
  bridge via `NSObject` KVO-free callbacks) — defined in presenters.md; the view layer depends only
  on that, not on data-layer types.

## Build order & integration checkpoints

0. Create these docs (done) → freeze the shared contracts above.
1. **data-layer**: git discovery + `openRepository` + `loadCommits` + models. _Checkpoint:_ unit tests
   on fixture repos parse commits/refs/diffs.
2. **coordinator + view-layer (skeleton)**: window, 3-pane split, drag-in sidebar that validates a
   repo. _Checkpoint:_ drag a folder → see it listed.
3. **presenters (timeline) + view-layer (commit list)**: render commits. _Checkpoint:_ timeline shows.
4. **diffs**: commit-detail presenter + TextKit 2 diff view. _Checkpoint:_ select commit → read diff.
5. **commit graph**: lane algorithm + custom cell.
6. **working copy**: status pane + diffs.
7. **resilience**: `RepoWatcher` → dirty banner → SHA-aware Refresh reconciliation. _Checkpoint:_ CLI
   squash/switch while open → no error, banner appears, Refresh preserves selection.
8. branches/remotes/worktrees in sidebar; polish (keyboard nav, side-by-side diff, syntax highlight).

## Status table (agents update as they go)

| Feature | Status | Owner | Notes |
|---------|--------|-------|-------|
| data-layer | **implemented (v1)** | Phase A | models, GitBackend, CLIGitBackend, parsers, FSEvents watcher; 11 tests green |
| presenters | **implemented (v1)** | Phase A | Timeline + CommitDetail with SHA-aware dirty/Refresh; 5 tests green |
| view-layer | skeleton only | — | AppKit 3-pane shell exists in app target; rich graph + diff view TODO |
| coordinator | skeleton only | — | AppDelegate + MainWindowController exist; bookmark store + navigation wiring TODO |
| qa-tester | **fixtures + seam tests (v1)** | Phase A | `FixtureRepo` + GitData/Presenter seam tests; snapshots/fuzz/mutation TODO |

### Phase A delivered (build & run verified)
- Xcode **workspace** `Elemental.xcworkspace` + app project `Elemental.xcodeproj` (bundle id
  `com.jasoncabot.elemental`, macOS 15, App Sandbox off, ad-hoc signed for local run).
- Local SPM packages under `Packages/`: `GitData`, `Presenters`, `TestSupport`.
- `xcodebuild` build succeeds **warning-free**; app launches; `swift test` green (16 tests total).
- Next: view-layer (commit list + graph + TextKit 2 diff view) and coordinator (bookmark store,
  navigation wiring) per their docs — these can now fan out against the frozen, compiling contracts.

## Cross-cutting rules

- Read-only by default; v1 has **no** staging/commit/rewrite actions.
- Never parse human-formatted git output — always `-z` / `--porcelain` / explicit `--format`.
- Set `GIT_OPTIONAL_LOCKS=0` on read commands; never take locks that fight the user's CLI.
- Never crash or blank out on disk change — degrade gracefully, key off SHA.
- **Zero warnings.** Treat every compiler/SwiftPM/Xcode warning as a defect and fix it by
  **implementing the recommended change**, never by suppressing it (no commenting-out, no `// swiftlint:disable`,
  no `_ =` silencing, no `@available` dodges) unless the suppression *is* the documented correct fix.
  Builds and CI must be warning-free.
- Don't over-architect: the four layer seams above are the only required abstractions.
- **Testing:** the QA tester owns the shared `FixtureRepo` library and the snapshot/fuzz/mutation
  harness; other agents consume those fixtures rather than inventing their own. Tests run along the
  seams (the contracts above) at the data-layer and presenter levels. **The GUI/view layer is
  explicitly not tested** — it's manually exercised by humans; correctness/"feel" is subjective.
