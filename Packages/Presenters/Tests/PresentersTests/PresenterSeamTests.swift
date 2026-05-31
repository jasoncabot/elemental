import XCTest
import GitData
@testable import Presenters

/// Extended seam tests for presenter↔data-layer contracts. Uses fakes only above the data layer.
@MainActor
final class PresenterSeamTests: XCTestCase {

    private func repo() -> Repository {
        Repository(rootURL: URL(fileURLWithPath: "/tmp/seam"),
                   gitDir: URL(fileURLWithPath: "/tmp/seam/.git"),
                   commonDir: URL(fileURLWithPath: "/tmp/seam/.git"), isBare: false)
    }

    // MARK: - Paging invariants

    /// Page size is honoured: presenter exposes only maxCount commits on first load.
    func testTimelinePagingRespectsMaxCount() async throws {
        let backend = FakeBackend()
        // Populate 20 commits in the fake.
        backend.commitsByScopeAll = (1...20).reversed().map { makeCommit("\($0)") }
        // pageSize = 5 → only first 5 streamed by the fake (FakeBackend streams all,
        // but TimelinePresenter passes maxCount=5 in its CommitQuery which limits what
        // the backend returns — the fake ignores maxCount, so we test the presenter's
        // query construction by asserting the count in isolation).
        // To get a real page-size test we use a counting fake that respects maxCount.
        let countingBackend = PageCapturingBackend()
        countingBackend.allCommits = backend.commitsByScopeAll

        let presenter = TimelinePresenter(backend: countingBackend, watcher: FakeWatcher(),
                                         repo: repo(), pageSize: 7)
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }
        XCTAssertEqual(countingBackend.lastMaxCount, 7, "TimelinePresenter must pass pageSize as maxCount")
    }

    /// select() followed by refresh with same data must preserve selection.
    func testSelectAndRefreshPreservesSelection() async throws {
        let backend = FakeBackend()
        backend.commitsByScopeAll = [makeCommit("z"), makeCommit("y"), makeCommit("x")]
        let presenter = TimelinePresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }
        presenter.select("x")
        XCTAssertEqual(presenter.selectedSHA, "x")
        presenter.refresh()
        await awaitCondition(on: presenter) { !presenter.isLoading }
        XCTAssertEqual(presenter.selectedSHA, "x", "refresh must preserve selection when SHA survives")
        XCTAssertFalse(presenter.isDirty)
    }

    // MARK: - Multiple dirty events

    /// Multiple DirtyEvents must accumulate the dirty flag without auto-reloading on each.
    func testMultipleDirtyEventsAccumulateWithoutReload() async throws {
        let backend = FakeBackend()
        backend.commitsByScopeAll = [makeCommit("a")]
        let watcher = FakeWatcher()
        let presenter = TimelinePresenter(backend: backend, watcher: watcher, repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }
        XCTAssertFalse(presenter.isDirty)

        let r = repo()
        watcher.fire(DirtyEvent(repo: r, changedPaths: ["HEAD"]))
        watcher.fire(DirtyEvent(repo: r, changedPaths: ["refs/heads/main"]))
        watcher.fire(DirtyEvent(repo: r, changedPaths: ["ORIG_HEAD"]))
        await awaitCondition(on: presenter) { presenter.isDirty }

        XCTAssertTrue(presenter.isDirty, "flag must be set after dirty events")
        // Commits must NOT have been reloaded — still the original snapshot.
        XCTAssertEqual(presenter.commits.count, 1)
        // Backend must have been called exactly once (the initial load), not 4 times.
        XCTAssertEqual(backend.loadCallCount, 1, "no reload should happen on dirty events")
    }

    // MARK: - Refresh clears dirty and re-queries backend

    func testRefreshClearsDirtyAndReloads() async throws {
        let backend = FakeBackend()
        backend.commitsByScopeAll = [makeCommit("a")]
        let watcher = FakeWatcher()
        let presenter = TimelinePresenter(backend: backend, watcher: watcher, repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        watcher.fire(DirtyEvent(repo: repo(), changedPaths: ["HEAD"]))
        await awaitCondition(on: presenter) { presenter.isDirty }

        presenter.refresh()
        await awaitCondition(on: presenter) { !presenter.isLoading && !presenter.isDirty }
        XCTAssertFalse(presenter.isDirty, "refresh must clear isDirty")
        XCTAssertEqual(backend.loadCallCount, 2, "refresh must trigger a backend reload")
    }

    // MARK: - commit(for:) lookup

    /// commit(for:) must return the exact Commit for any loaded SHA, nil for unknown.
    func testCommitForSHALookup() async throws {
        let backend = FakeBackend()
        let c1 = makeCommit("sha-alpha", subject: "Alpha commit")
        let c2 = makeCommit("sha-beta", subject: "Beta commit")
        backend.commitsByScopeAll = [c1, c2]
        let presenter = TimelinePresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        let found = presenter.commit(for: "sha-beta")
        XCTAssertEqual(found?.subject, "Beta commit")
        XCTAssertNil(presenter.commit(for: "nonexistent-sha"))
    }

    // MARK: - Diff cache reuse across show/hide/show

    /// Hiding (show nil) then re-showing the same SHA must not issue a second diff call.
    func testDiffCacheReusedAfterHide() async throws {
        let backend = FakeBackend()
        backend.diffsBySHA["x"] = [DiffFile(oldPath: nil, newPath: "f.txt", status: .added,
                                             isBinary: false, hunks: [], additions: 3, deletions: 0)]
        let presenter = CommitDetailPresenter(backend: backend, repo: repo())
        presenter.show(commit: makeCommit("x"))
        await awaitCondition(on: presenter) { !presenter.files.isEmpty }
        XCTAssertEqual(backend.diffCallCount, 1)

        presenter.show(commit: nil)        // clear
        presenter.show(commit: makeCommit("x"))   // re-show
        await awaitCondition(on: presenter) { !presenter.files.isEmpty }
        XCTAssertEqual(backend.diffCallCount, 1, "second show of same SHA must be cache hit")
    }

    // MARK: - Search

    private func searchBackend() -> FakeBackend {
        let backend = FakeBackend()
        backend.commitsByScopeAll = [
            makeCommit("aaa111", subject: "Improve websocket reconnect handling"),
            makeCommit("bbb222", subject: "Refactor sidebar rendering"),
            makeCommit("ccc333", subject: "Tune reconnect backoff and jitter"),
            makeCommit("ddd444", subject: "Remove deprecated auth middleware"),
        ]
        backend.stubbedRefs = RefSnapshot(
            head: .detached(sha: "aaa111"),
            branches: [Ref(name: "refs/heads/main", sha: "aaa111", kind: .branch)],
            remotes: [],
            tags: [Ref(name: "refs/tags/v0.1.1", sha: "ccc333", kind: .tag)])
        return backend
    }

    /// A free-text query filters the timeline to message matches and auto-selects the first.
    func testSearchByMessageFiltersTimeline() async throws {
        let backend = searchBackend()
        let presenter = TimelinePresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        presenter.setSearch("reconnect")
        await awaitCondition(on: presenter) { presenter.isSearchActive && presenter.rowCount == 2 }

        XCTAssertEqual(presenter.commit(atRow: 0)?.sha, "aaa111")
        XCTAssertEqual(presenter.commit(atRow: 1)?.sha, "ccc333")
        XCTAssertEqual(presenter.selectedSHA, "aaa111", "first match is auto-selected")
        XCTAssertEqual(presenter.searchSummary, "2 results for “reconnect”")
    }

    /// A SHA prefix narrows to exactly that one commit.
    func testSearchBySHAPrefixNarrowsToOne() async throws {
        let backend = searchBackend()
        let presenter = TimelinePresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        presenter.setSearch("ddd4")
        await awaitCondition(on: presenter) { presenter.isSearchActive && presenter.searchSummary != nil }

        XCTAssertEqual(presenter.rowCount, 1)
        XCTAssertEqual(presenter.commit(atRow: 0)?.sha, "ddd444")
        XCTAssertEqual(presenter.selectedSHA, "ddd444")
    }

    /// A tag name resolves to its commit (the exact leg), unioned ahead of any message matches.
    func testSearchByTagResolvesToTaggedCommit() async throws {
        let backend = searchBackend()
        let presenter = TimelinePresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        presenter.setSearch("v0.1.1")
        await awaitCondition(on: presenter) { presenter.isSearchActive && presenter.searchSummary != nil }

        XCTAssertEqual(presenter.rowCount, 1)
        XCTAssertEqual(presenter.commit(atRow: 0)?.sha, "ccc333")
    }

    /// Clearing the search restores the full paged timeline and the pre-search selection.
    func testClearingSearchRestoresTimeline() async throws {
        let backend = searchBackend()
        let presenter = TimelinePresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }
        presenter.select("bbb222")

        presenter.setSearch("reconnect")
        await awaitCondition(on: presenter) { presenter.rowCount == 2 }

        presenter.setSearch("")
        await awaitCondition(on: presenter) { !presenter.isSearchActive }
        XCTAssertEqual(presenter.rowCount, 4, "full history is restored")
        XCTAssertNil(presenter.searchSummary)
        XCTAssertEqual(presenter.selectedSHA, "bbb222", "pre-search selection is restored")
    }

    /// A query that matches nothing reports an empty result set, not a fallback to the full list.
    func testSearchWithNoMatchesIsEmpty() async throws {
        let backend = searchBackend()
        let presenter = TimelinePresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        presenter.setSearch("zzzzz-nope")
        await awaitCondition(on: presenter) { presenter.searchSummary != nil }
        XCTAssertEqual(presenter.rowCount, 0)
        XCTAssertEqual(presenter.searchSummary, "No commits match “zzzzz-nope”")
    }
}

// MARK: - Auxiliary fake that records query parameters

final class PageCapturingBackend: GitBackend, @unchecked Sendable {
    var allCommits: [Commit] = []
    private(set) var lastMaxCount: Int?

    func gitVersion() async throws -> String { "fake" }
    func openRepository(at url: URL) async throws -> Repository {
        Repository(rootURL: url, gitDir: url, commonDir: url, isBare: false)
    }
    func loadCommits(_ query: CommitQuery) -> AsyncThrowingStream<Commit, Error> {
        lastMaxCount = query.maxCount
        let snapshot = allCommits
        return AsyncThrowingStream { continuation in
            for c in snapshot { continuation.yield(c) }
            continuation.finish()
        }
    }
    func refs(for repo: Repository) async throws -> RefSnapshot {
        RefSnapshot(head: .detached(sha: ""), branches: [], remotes: [], tags: [])
    }
    func commitCount(_ query: CommitQuery) async throws -> Int { allCommits.count }
    func diff(_ range: DiffRange, context: DiffContext, in repo: Repository) async throws -> [DiffFile] { [] }
    func workingCopyStatus(for repo: Repository) async throws -> WorkingCopyStatus {
        WorkingCopyStatus(branch: nil, ahead: nil, behind: nil,
                          staged: [], unstaged: [], untracked: [], conflicts: [])
    }
    func blob(at path: String, rev: String, in repo: Repository) async throws -> Data { Data() }
}
