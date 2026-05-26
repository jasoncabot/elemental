# Feature: Coordinator (App Shell & Wiring)

> The app's backbone: lifecycle, windows, navigation wiring, and persistence of which repos are open.
> Creates presenters and connects them to views. See [ORCHESTRATOR.md](ORCHESTRATOR.md).

## Purpose

Own the application shell and the **composition root**: construct the data layer, instantiate
presenters, build the window + views, and route navigation between sidebar → timeline → detail. Also
owns the **repo bookmark store** (which folders the user has dragged in).

## Key types & responsibilities

- **`AppDelegate`** — app lifecycle; builds the singletons: `GitService` (data layer), `RepoWatcher`,
  the bookmark store; opens the main window.
- **`MainWindowController: NSWindowController`** — owns the `NSSplitView` shell and its child view
  controllers; the toolbar; window restoration.
- **`AppCoordinator`** — the wiring hub. Creates presenters (`Sidebar`, `Timeline`, `CommitDetail`,
  `WorkingCopy`), injects the data layer, and connects selection flow:
  - repo/scope selected in sidebar → set `TimelinePresenter` query;
  - commit selected in timeline → set `CommitDetailPresenter` SHA;
  - Refresh action → forwarded to the relevant presenter.
  Keeps presenters decoupled from each other; all cross-pane navigation passes through here.
- **`RepoBookmarkStore`** — persists the set of open repositories. Non-sandboxed, so plain
  `URL.bookmarkData()` (no security scope needed) saved to `bookmarks.json` in Application Support.
  Validates a dragged folder is a repo via `GitService.openRepository(at:)` before adding; drag-out
  removes. Restores open repos on launch.

## Drag-in / drag-out flow

1. Folder URL dropped on sidebar → `AppCoordinator` asks `GitService.openRepository(at:)`.
2. On success → `RepoBookmarkStore` saves a bookmark; `SidebarPresenter` gains the repo; watcher
   subscription starts.
3. Drag-out → remove bookmark, stop watcher subscription, drop presenters' repo state.

## Lifecycle & restoration

- On launch, resolve saved bookmarks → re-open repos (skip/flag any that no longer resolve, never
  crash). Re-establish `RepoWatcher` subscriptions.
- On quit, persist open-repo set + last selection (best-effort).

## Build / distribution notes

- AppKit app target, macOS 15 deployment, **no App Sandbox entitlement**.
- **Developer ID** signing + **notarization** (`notarytool`) for DMG distribution; hardened runtime on,
  with the entitlement to allow executing the system `git` if required by hardened-runtime checks.
- Open-source license at repo root (confirm MIT/Apache-2.0 at init).

## Non-goals

- No business logic beyond wiring (that lives in presenters).
- No git invocation directly (always via `GitService`).
- No multi-window/document model in v1 (single main window; design leaves room to add later).

## Verification

- Drag a folder in → it persists and re-opens on relaunch.
- Drag out → it's removed and its watcher stops.
- Launch with a saved bookmark whose folder was deleted/moved → app starts, flags the missing repo, no
  crash.
- Selection flow: pick repo → branch → commit reaches the detail pane end-to-end.
