# Feature: Presenters (View-Models)

> Main-actor layer between the data layer and the AppKit views. Owns all UI-facing state and the
> SHA-aware dirty/Refresh reconciliation. No AppKit imports, no `Process`. See
> [ORCHESTRATOR.md](ORCHESTRATOR.md).

## Purpose

Translate data-layer models into observable, view-ready state; own selection, paging, and the
**disk-change resilience UX**. Depends only on the data-layer protocols + models
([data-layer.md](data-layer.md)). Exposes a thin observation interface the view layer binds to.

## Contracts exposed (presenter→view binding)

The view layer must not import data-layer types. Presenters expose state + change notifications via a
minimal interface (pick one, document it once and keep it consistent):

```
protocol PresenterObserving: AnyObject { func presenterDidUpdate(_ presenter: AnyObject) }
```
Each presenter holds a weak `observer` and calls back on the main actor after state changes. (KVO-free,
AppKit-friendly. A `@Observable` bridge is acceptable if it stays internal and the view binds via the
callback only.)

## Presenters & responsibilities

- **`SidebarPresenter`** — list of open repositories (from the bookmark store, owned by coordinator)
  and per-repo refs (`RefSnapshot`). Exposes branches/tags/remotes grouped; selection of a repo + a
  scope drives the timeline.
- **`TimelinePresenter`** — owns the current `CommitQuery`, consumes `loadCommits` stream, holds the
  **SHA-keyed commit array** + an index for fast lookup, handles paging (load-more on scroll), and the
  current selected SHA.
- **`CommitDetailPresenter`** — for a selected SHA, loads `diff(for:)`, exposes metadata + `[DiffFile]`,
  the selected file, and diff view mode (unified/side-by-side). Caches per-SHA diffs (SHA is immutable,
  so cache entries never go stale).
- **`WorkingCopyPresenter`** — `workingCopyStatus` + per-file diffs (`.workingStaged`/`.workingUnstaged`).

## Disk-change resilience (the headline logic lives here)

Each repo-scoped presenter subscribes to `RepoWatcher.events(for:)`. On a `DirtyEvent`:

1. **Do not reload.** Set `isDirty = true` and notify the observer → view shows the
   **"Repository changed on disk — Refresh"** banner. Current state (SHA-keyed) stays rendered.
2. On user **Refresh** (action routed from the view): re-fetch `RefSnapshot` + re-run the timeline
   query + working-copy status. Then **reconcile**:
   - If the previously selected SHA still exists → keep selection + scroll position.
   - If it's gone (e.g. squashed away) → select the nearest reachable commit (walk first-parent from
     the new HEAD, or nearest by commit date) and clear the stale banner. **Never** throw or blank.
   - Loaded per-SHA diffs in `CommitDetailPresenter` remain valid and need no refetch.

This is why the model is SHA-keyed: refs changing can't invalidate displayed content, only the
mapping, which Refresh reconciles deliberately.

## Concurrency

- Presenters are `@MainActor`. They `await` the actor-backed data API and apply results on the main
  actor. In-flight loads are cancellable `Task`s stored per presenter; a new query cancels the prior.
- Streamed commits append incrementally with batched observer notifications (avoid per-row churn).

## Non-goals

- No AppKit / view construction.
- No direct git invocation.
- No write actions in v1.

## Verification

- Unit tests with a **fake `GitBackend`** + **fake `RepoWatcher`** (in-memory) asserting:
  - timeline paging appends correctly and selection is preserved across appends;
  - on `DirtyEvent`, `isDirty` flips and no reload happens until Refresh;
  - Refresh with surviving SHA preserves selection; Refresh with removed SHA falls back without error;
  - per-SHA diff cache is reused (no second backend call for the same SHA).
