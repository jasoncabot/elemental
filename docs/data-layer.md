# Feature: Data Layer

> Foundation feature. Owns all access to git and the models everything else consumes. No UI, no
> AppKit. See [ORCHESTRATOR.md](ORCHESTRATOR.md) for how this fits the whole.

## Purpose

Provide a clean, async, cancellable API over the **user's own `git`** binary, returning **immutable,
SHA-keyed value-type models**, plus a watcher that signals when the repo changed on disk. This layer
is the reason Elemental is resilient and forward-compatible: all capability comes from the user's git,
so new git features (worktrees, reftable, partial clone, SHA-256, future formats) need no changes
here.

## Contracts exposed (normative — frozen for other layers)

### Models (immutable structs, `Sendable`)
- `Repository { rootURL, gitDir, commonDir, isBare, worktrees: [Worktree] }`
- `Commit { sha, parents: [String], author: Signature, committer: Signature, authorDate,
  commitDate, subject, body, refNames: [String] }`
- `Signature { name, email }`
- `RefSnapshot { head: HeadState, branches: [Ref], remotes: [Ref], tags: [Ref] }` where
  `Ref { name, sha, upstream?, ahead?, behind? }` and `HeadState` is `.attached(branch, sha)` or
  `.detached(sha)`.
- `DiffFile { oldPath?, newPath?, status (added/modified/deleted/renamed/copied), isBinary,
  hunks: [DiffHunk], additions, deletions }`
- `DiffHunk { oldStart, oldCount, newStart, newCount, header, lines: [DiffLine] }`
- `DiffLine { kind (context/added/removed), oldLineNo?, newLineNo?, text }`
- `WorkingCopyStatus { branch?, ahead?, behind?, staged: [FileStatus], unstaged: [FileStatus],
  untracked: [FileStatus], conflicts: [FileStatus] }`

### `GitBackend` protocol (async, cancellable)
```
protocol GitBackend: Sendable {
  func openRepository(at url: URL) async throws -> Repository
  func loadCommits(_ query: CommitQuery) -> AsyncThrowingStream<Commit, Error>
  func refs(for repo: Repository) async throws -> RefSnapshot
  func diff(for sha: String, in repo: Repository) async throws -> [DiffFile]
  func diff(range: DiffRange, in repo: Repository) async throws -> [DiffFile]   // working/staged/range
  func workingCopyStatus(for repo: Repository) async throws -> WorkingCopyStatus
  func blob(at path: String, rev: String, in repo: Repository) async throws -> Data
  func gitVersion() async throws -> String
}
```
`CommitQuery { repo, scope (.head/.branch(name)/.ref(name)/.all), maxCount?, skip?, since? }`.
`DiffRange { .workingUnstaged / .workingStaged / .commit(sha) / .between(a,b) }`.

### `RepoWatcher`
```
protocol RepoWatcher { func events(for repo: Repository) -> AsyncStream<DirtyEvent> }
```
`DirtyEvent { repo, changedPaths }`. Coalesced/debounced (~300ms).

## Key types & responsibilities (implementation)

- **`CLIGitBackend: GitBackend`** — the only backend. Discovers git (login-shell `PATH`, fallback
  `/usr/bin/git`), caches version. Each call builds a `git` invocation with machine-readable flags and
  parses NUL-delimited output. Sets `GIT_OPTIONAL_LOCKS=0` on reads.
- **`GitService` actor** — wraps `CLIGitBackend`; serializes/coalesces per-repo requests, owns process
  lifecycle, maps Swift `Task` cancellation → child process termination, streams large stdout via
  `Pipe`/`FileHandle.bytes` and parses incrementally (never buffer a 100k-commit log in one String).
- **`GitProcess`** — small helper around `Process`: argv, cwd, env, async stdout/stderr, exit handling,
  cancellation.

## Representative git commands

| Need | Command |
|------|---------|
| repo root/dirs | `git rev-parse --show-toplevel --git-dir --git-common-dir --is-bare-repository` |
| worktrees | `git worktree list --porcelain` |
| refs | `git for-each-ref --format=<NUL fields> refs/heads refs/remotes refs/tags` + `symbolic-ref -q HEAD` |
| commits | `git log --parents --format=<NUL custom: %H %P %an %ae %aI %cn %ce %cI %s %b %D>` + paging |
| commit diff | `git show <sha> --patch --numstat -z -M -C` |
| unstaged | `git diff --patch --numstat -z -M -C` |
| staged | `git diff --cached --patch --numstat -z -M -C` |
| status | `git status --porcelain=v2 -z --branch` |
| blob | `git cat-file --batch` / `--batch-check` |

## Worktrees & submodules

Resolve `.git` gitlinks via `--git-dir` / `--git-common-dir`. The `RepoWatcher` watches the
**common dir**. Non-sandboxed, so paths pointing outside the repo just work — no silent failures.

## Non-goals

- No writes: no staging, commit, checkout, rebase, fetch/push. (Read commands only.)
- No libgit2, no direct object/packfile parsing.
- No caching policy beyond in-memory request coalescing (presenters own UI-level caching).

## Verification

- Unit tests build **fixture repos** in `setUp` via the CLI (init temp repo, make commits, branches,
  a merge, a rename, a binary file) and assert parsed `Commit`/`DiffFile`/`RefSnapshot` shapes.
- Include a **bare repo**, a **worktree**, and a **submodule** fixture.
- Cancellation test: start a large `loadCommits` stream, cancel the task, assert the child process
  terminates.
- Robustness: mutate a fixture repo on disk (extra commit, `git gc`) between calls; assert no throw on
  reads of still-present SHAs.
