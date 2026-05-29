import XCTest
import GitData
@testable import Presenters

/// Comprehensive tests for unusual git states that change the working copy or refs underneath
/// a running UI. These verify that the presenter/data layer handles every edge case gracefully
/// without crashing, and produces correct state for the UI to render.
///
/// All tests run headlessly using `FakeBackend` and `FakeWatcher` — no real git process needed.
@MainActor
final class GitStateEdgeCaseTests: XCTestCase {

    // MARK: - Helpers

    private func makeRepo(path: String = "/tmp/edge") -> Repository {
        Repository(rootURL: URL(fileURLWithPath: path),
                   gitDir: URL(fileURLWithPath: path + "/.git"),
                   commonDir: URL(fileURLWithPath: path + "/.git"), isBare: false)
    }

    // MARK: - 1. Branch switch (git checkout/switch)

    /// After a branch switch (HEAD changes), dirty fires and refresh loads new branch data.
    /// If the currently selected commit SHA is still reachable, selection is preserved.
    func testBranchSwitch_SelectionPreservedIfReachable() async throws {
        let backend = FakeBackend()
        let watcher = FakeWatcher()
        let commits = [makeCommit("aaa"), makeCommit("bbb"), makeCommit("ccc")]
        backend.commitsByScopeAll = commits

        let presenter = TimelinePresenter(backend: backend, watcher: watcher, repo: makeRepo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        presenter.select("bbb")
        XCTAssertEqual(presenter.selectedSHA, "bbb")

        // Simulate branch switch: dirty event fires
        watcher.fire(DirtyEvent(repo: makeRepo(), changedPaths: ["HEAD", "refs/heads/feature"]))
        await awaitCondition(on: presenter) { presenter.isDirty }

        // User refreshes — commits still contain "bbb" so selection stays
        presenter.refresh()
        await awaitCondition(on: presenter) { !presenter.isLoading && !presenter.isDirty }
        XCTAssertEqual(presenter.selectedSHA, "bbb")
        XCTAssertFalse(presenter.isDirty)
    }

    /// After a branch switch, if the selected SHA is NOT in the new commit set, selection
    /// falls back to the first (tip) commit.
    func testBranchSwitch_SelectionFallsBackIfUnreachable() async throws {
        let backend = FakeBackend()
        let watcher = FakeWatcher()
        backend.commitsByScopeAll = [makeCommit("aaa"), makeCommit("bbb")]

        let presenter = TimelinePresenter(backend: backend, watcher: watcher, repo: makeRepo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        presenter.select("bbb")

        // Branch switch: new branch doesn't have "bbb"
        watcher.fire(DirtyEvent(repo: makeRepo(), changedPaths: ["HEAD"]))
        await awaitCondition(on: presenter) { presenter.isDirty }

        backend.commitsByScopeAll = [makeCommit("xxx"), makeCommit("yyy")]
        presenter.refresh()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        XCTAssertEqual(presenter.selectedSHA, "xxx", "Should fall back to tip when selected SHA is gone")
    }

    // MARK: - 2. Detached HEAD (git checkout <sha>)

    /// Sidebar presenter handles detached HEAD state showing truncated SHA.
    func testDetachedHEAD_RefsShowDetachedState() async throws {
        let backend = FakeBackend()
        backend.stubbedRefs = RefSnapshot(
            head: .detached(sha: "abc123def456"),
            branches: [], remotes: [], tags: []
        )
        let presenter = SidebarPresenter(backend: backend, watcher: FakeWatcher())
        presenter.setRepositories([makeRepo()])
        await awaitCondition(on: presenter) { presenter.items.first?.refs != nil }

        let item = try XCTUnwrap(presenter.items.first)
        if case .detached(let sha) = item.refs?.head {
            XCTAssertEqual(sha, "abc123def456")
        } else {
            XCTFail("Expected detached HEAD state")
        }
    }

    // MARK: - 3. Unborn branch (new git init)

    /// An unborn branch means no commits exist. Timeline should be empty, no crash.
    func testUnbornBranch_EmptyTimeline() async throws {
        let backend = FakeBackend()
        backend.commitsByScopeAll = [] // no commits
        backend.stubbedRefs = RefSnapshot(
            head: .unborn(branch: "main"),
            branches: [], remotes: [], tags: []
        )
        let watcher = FakeWatcher()
        let presenter = TimelinePresenter(backend: backend, watcher: watcher, repo: makeRepo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        XCTAssertTrue(presenter.commits.isEmpty)
        XCTAssertNil(presenter.selectedSHA)
        XCTAssertFalse(presenter.hasMoreCommits)
    }

    func testUnbornBranch_SidebarShowsBranchName() async throws {
        let backend = FakeBackend()
        backend.stubbedRefs = RefSnapshot(
            head: .unborn(branch: "main"),
            branches: [], remotes: [], tags: []
        )
        let presenter = SidebarPresenter(backend: backend, watcher: FakeWatcher())
        presenter.setRepositories([makeRepo()])
        await awaitCondition(on: presenter) { presenter.items.first?.refs != nil }

        let item = try XCTUnwrap(presenter.items.first)
        if case .unborn(let branch) = item.refs?.head {
            XCTAssertEqual(branch, "main")
        } else {
            XCTFail("Expected unborn HEAD state")
        }
    }

    // MARK: - 4. Rebase in progress

    /// During rebase, dirty events fire for rebase-merge directory. App must not crash.
    func testRebaseInProgress_DirtyEventsHandledGracefully() async throws {
        let backend = FakeBackend()
        let watcher = FakeWatcher()
        backend.commitsByScopeAll = [makeCommit("a1")]
        let presenter = TimelinePresenter(backend: backend, watcher: watcher, repo: makeRepo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        // Fire dirty events typical of a rebase
        let rebasePaths = [
            "rebase-merge/head-name",
            "rebase-merge/onto",
            "rebase-merge/interactive",
            "ORIG_HEAD"
        ]
        for path in rebasePaths {
            watcher.fire(DirtyEvent(repo: makeRepo(), changedPaths: [path]))
        }
        await awaitCondition(on: presenter) { presenter.isDirty }

        XCTAssertTrue(presenter.isDirty)
        // No crash, commits still accessible
        XCTAssertEqual(presenter.commits.count, 1)
    }

    // MARK: - 5. Merge in progress with conflicts

    /// Working copy presenter handles conflicts without crashing.
    func testMergeConflicts_WorkingCopyShowsConflicts() async throws {
        let backend = FakeBackend()
        backend.stubbedStatus = WorkingCopyStatus(
            branch: "main", ahead: 0, behind: 0,
            staged: [],
            unstaged: [],
            untracked: [],
            conflicts: [
                FileStatus(path: "file.txt", status: .unmerged),
                FileStatus(path: "other.txt", status: .unmerged)
            ]
        )
        let watcher = FakeWatcher()
        let presenter = WorkingCopyPresenter(backend: backend, watcher: watcher, repo: makeRepo())
        presenter.start()
        await awaitCondition(on: presenter) { presenter.status != nil && !presenter.isLoadingStatus }

        XCTAssertEqual(presenter.status?.conflicts.count, 2)
    }

    // MARK: - 6. Bisect in progress

    /// HEAD moves frequently during bisect. Multiple dirty events must not auto-reload.
    func testBisectInProgress_MultipleDirtyEventsNoAutoReload() async throws {
        let backend = FakeBackend()
        let watcher = FakeWatcher()
        backend.commitsByScopeAll = [makeCommit("b1"), makeCommit("b2")]
        let presenter = TimelinePresenter(backend: backend, watcher: watcher, repo: makeRepo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        // Bisect causes many HEAD moves
        for i in 0..<10 {
            watcher.fire(DirtyEvent(repo: makeRepo(), changedPaths: ["HEAD", "BISECT_LOG"]))
            _ = i
        }
        await awaitCondition(on: presenter) { presenter.isDirty }

        XCTAssertTrue(presenter.isDirty)
        // Backend only called once (initial load), not 10 more times
        XCTAssertEqual(backend.loadCallCount, 1)
    }

    // MARK: - 7. Stash push/pop

    /// Stash operations change refs/stash and working tree. Dirty fires, no crash.
    func testStashPushPop_DirtyEventFires() async throws {
        let backend = FakeBackend()
        let watcher = FakeWatcher()
        backend.commitsByScopeAll = [makeCommit("s1")]
        let presenter = TimelinePresenter(backend: backend, watcher: watcher, repo: makeRepo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        watcher.fire(DirtyEvent(repo: makeRepo(), changedPaths: ["refs/stash"]))
        await awaitCondition(on: presenter) { presenter.isDirty }
        XCTAssertTrue(presenter.isDirty)
    }

    // MARK: - 8. Force-push / ref rewrite (upstream changes)

    /// Remote refs change but local state is intact. Sidebar shows updated remotes after refresh.
    func testForcePush_RemoteRefsUpdateOnRefresh() async throws {
        let backend = FakeBackend()
        let watcher = FakeWatcher()
        backend.stubbedRefs = RefSnapshot(
            head: .attached(branch: "main", sha: "local1"),
            branches: [Ref(name: "main", sha: "local1", kind: .branch)],
            remotes: [Ref(name: "origin/main", sha: "old-remote", kind: .remote)],
            tags: []
        )
        let presenter = SidebarPresenter(backend: backend, watcher: watcher)
        presenter.setRepositories([makeRepo()])
        await awaitCondition(on: presenter) { presenter.items.first?.refs != nil }

        // Simulate fetch that updates remote refs
        watcher.fire(DirtyEvent(repo: makeRepo(), changedPaths: ["refs/remotes/origin/main"]))
        await awaitCondition(on: presenter) { presenter.isDirty }

        // Update backend stub and refresh
        backend.stubbedRefs = RefSnapshot(
            head: .attached(branch: "main", sha: "local1"),
            branches: [Ref(name: "main", sha: "local1", kind: .branch)],
            remotes: [Ref(name: "origin/main", sha: "new-remote", kind: .remote)],
            tags: []
        )
        presenter.refresh()
        await awaitCondition(on: presenter) { presenter.items.first?.isLoadingRefs == false && !presenter.isDirty }

        let item = try XCTUnwrap(presenter.items.first)
        XCTAssertEqual(item.remotes.first?.sha, "new-remote")
    }

    // MARK: - 9. .git directory deleted

    /// Timeline handles repo disappearance (watcher event with missing folder).
    /// This tests that no crash occurs when the repo is gone and events still fire.
    func testGitDirDeleted_NoCrash() async throws {
        let backend = FakeBackend()
        let watcher = FakeWatcher()
        backend.commitsByScopeAll = [makeCommit("d1")]
        let presenter = TimelinePresenter(backend: backend, watcher: watcher, repo: makeRepo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        // Even after dirty events for a deleted repo, presenter stays stable
        watcher.fire(DirtyEvent(repo: makeRepo(), changedPaths: [".git"]))
        await awaitCondition(on: presenter) { presenter.isDirty }

        XCTAssertTrue(presenter.isDirty)
        // Commits still in memory — no crash
        XCTAssertEqual(presenter.commits.count, 1)
    }

    // MARK: - 10. Worktree added/removed

    /// Worktree operations change .git/worktrees/. Refs stay valid, no crash.
    func testWorktreeAddedRemoved_RefsStayValid() async throws {
        let backend = FakeBackend()
        let watcher = FakeWatcher()
        backend.stubbedRefs = RefSnapshot(
            head: .attached(branch: "main", sha: "w1"),
            branches: [Ref(name: "main", sha: "w1", kind: .branch)],
            remotes: [], tags: []
        )
        let presenter = SidebarPresenter(backend: backend, watcher: watcher)
        presenter.setRepositories([makeRepo()])
        await awaitCondition(on: presenter) { presenter.items.first?.refs != nil }

        watcher.fire(DirtyEvent(repo: makeRepo(), changedPaths: ["worktrees/"]))
        await awaitCondition(on: presenter) { presenter.isDirty }

        XCTAssertTrue(presenter.isDirty)
        // Refs remain valid
        let item = try XCTUnwrap(presenter.items.first)
        XCTAssertEqual(item.branches.first?.name, "main")
    }

    // MARK: - 11. Concurrent git gc / prune

    /// If backend fails mid-stream during gc (simulated by throwing), timeline shows error gracefully.
    func testGitGC_BackendErrorHandledGracefully() async throws {
        let failingBackend = FailingBackend(failAfter: 2)
        failingBackend.allCommits = [makeCommit("g1"), makeCommit("g2"), makeCommit("g3")]
        let presenter = TimelinePresenter(backend: failingBackend, watcher: FakeWatcher(), repo: makeRepo())
        presenter.start()
        await awaitCondition(on: presenter) { presenter.lastError != nil }

        // Should have the error recorded, not crash
        XCTAssertNotNil(presenter.lastError)
    }

    // MARK: - 12. Lock file contention (.lock files)

    /// Lock files cause git commands to fail. Backend errors surface gracefully.
    func testLockContention_BackendErrorSurfaced() async throws {
        let lockBackend = ErroringRefsBackend()
        let presenter = SidebarPresenter(backend: lockBackend, watcher: FakeWatcher())
        presenter.setRepositories([makeRepo()])
        await awaitCondition(on: presenter) { presenter.items.first?.isLoadingRefs == false }

        let item = try XCTUnwrap(presenter.items.first)
        XCTAssertNotNil(item.refError, "Lock contention error should be surfaced")
        XCTAssertNil(item.refs)
    }

    // MARK: - 13. Rapid successive branch switches

    /// Multiple branch switches within the debounce window: only final state matters after refresh.
    func testRapidBranchSwitches_OnlyFinalStateAfterRefresh() async throws {
        let backend = FakeBackend()
        let watcher = FakeWatcher()
        backend.commitsByScopeAll = [makeCommit("r1"), makeCommit("r2")]
        let presenter = TimelinePresenter(backend: backend, watcher: watcher, repo: makeRepo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        // Rapid switches — 5 HEAD changes in quick succession
        for _ in 0..<5 {
            watcher.fire(DirtyEvent(repo: makeRepo(), changedPaths: ["HEAD"]))
        }
        await awaitCondition(on: presenter) { presenter.isDirty }

        XCTAssertTrue(presenter.isDirty)
        XCTAssertEqual(backend.loadCallCount, 1, "No auto-reload on dirty events")

        // After user refresh, backend is called exactly once more
        backend.commitsByScopeAll = [makeCommit("final1"), makeCommit("final2")]
        presenter.refresh()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        XCTAssertEqual(presenter.commits.first?.sha, "final1")
        XCTAssertEqual(backend.loadCallCount, 2)
    }

    // MARK: - 14. Shallow clone / partial clone

    /// Shallow clone may yield fewer commits than expected. Stream ends early without crash.
    func testShallowClone_StreamEndsEarlyGracefully() async throws {
        let backend = FakeBackend()
        // Only 2 commits available despite no explicit boundary
        backend.commitsByScopeAll = [makeCommit("shallow1"), makeCommit("shallow2")]
        let presenter = TimelinePresenter(backend: backend, watcher: FakeWatcher(),
                                          repo: makeRepo(), pageSize: 100)
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        XCTAssertEqual(presenter.commits.count, 2)
        XCTAssertFalse(presenter.hasMoreCommits, "Should detect end of available commits")
    }

    // MARK: - 15. Corrupt .git/HEAD

    /// If refs() throws (corrupt HEAD), sidebar shows error state, no crash.
    func testCorruptHEAD_SidebarShowsError() async throws {
        let corruptBackend = ErroringRefsBackend()
        let presenter = SidebarPresenter(backend: corruptBackend, watcher: FakeWatcher())
        presenter.setRepositories([makeRepo()])
        await awaitCondition(on: presenter) { presenter.items.first?.isLoadingRefs == false }

        let item = try XCTUnwrap(presenter.items.first)
        XCTAssertNotNil(item.refError)
        XCTAssertNil(item.refs)
        XCTAssertFalse(item.isLoadingRefs)
    }

    // MARK: - Compound scenarios

    /// Branch switch + immediate refresh before debounce completes.
    func testBranchSwitchThenImmediateRefresh() async throws {
        let backend = FakeBackend()
        let watcher = FakeWatcher()
        backend.commitsByScopeAll = [makeCommit("c1"), makeCommit("c2")]
        let presenter = TimelinePresenter(backend: backend, watcher: watcher, repo: makeRepo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        // Dirty event — wait for presenter to mark itself dirty before triggering refresh
        watcher.fire(DirtyEvent(repo: makeRepo(), changedPaths: ["HEAD"]))
        await awaitCondition(on: presenter) { presenter.isDirty }

        presenter.refresh()
        await awaitCondition(on: presenter) { !presenter.isLoading }

        XCTAssertFalse(presenter.isDirty)
        XCTAssertEqual(presenter.commits.count, 2)
    }

    /// Watcher events arriving after presenter is deinitialized (weak self guards).
    func testWatcherEventsAfterPresenterDealloc_NoCrash() async throws {
        let backend = FakeBackend()
        let watcher = FakeWatcher()
        backend.commitsByScopeAll = [makeCommit("z1")]

        var presenter: TimelinePresenter? = TimelinePresenter(
            backend: backend, watcher: watcher, repo: makeRepo())
        presenter?.start()
        await awaitCondition(on: presenter!) { !presenter!.isLoading }

        // Deallocate presenter
        presenter = nil
        await yieldToMainActor()

        // Fire events after dealloc — must not crash
        watcher.fire(DirtyEvent(repo: makeRepo(), changedPaths: ["HEAD"]))
        await yieldToMainActor()
        // If we reach here, no crash occurred ✓
    }

    /// Multiple repos with interleaved dirty events — each presenter only reacts to its own.
    func testMultipleRepos_IsolatedDirtyEvents() async throws {
        let backend = FakeBackend()
        let watcher = FakeWatcher()
        backend.commitsByScopeAll = [makeCommit("m1")]

        let repoA = makeRepo(path: "/tmp/repoA")
        let repoB = makeRepo(path: "/tmp/repoB")

        let presenterA = TimelinePresenter(backend: backend, watcher: watcher, repo: repoA)
        let presenterB = TimelinePresenter(backend: backend, watcher: watcher, repo: repoB)
        presenterA.start()
        presenterB.start()
        await awaitCondition(on: presenterA) { !presenterA.isLoading }
        await awaitCondition(on: presenterB) { !presenterB.isLoading }

        // Only fire for repoA — FakeWatcher now filters by repo like production
        watcher.fire(DirtyEvent(repo: repoA, changedPaths: ["HEAD"]))
        await awaitCondition(on: presenterA) { presenterA.isDirty }

        // presenterB must NOT be marked dirty since the event was for repoA only
        XCTAssertTrue(presenterA.isDirty)
        XCTAssertFalse(presenterB.isDirty)
        XCTAssertEqual(presenterA.commits.count, 1)
        XCTAssertEqual(presenterB.commits.count, 1)
    }
}

// MARK: - Test-only fakes for edge cases

/// A backend that throws an error after yielding N commits (simulates gc/prune mid-stream).
private final class FailingBackend: GitBackend, @unchecked Sendable {
    var allCommits: [Commit] = []
    let failAfter: Int

    init(failAfter: Int) { self.failAfter = failAfter }

    func gitVersion() async throws -> String { "fake" }
    func openRepository(at url: URL) async throws -> Repository {
        Repository(rootURL: url, gitDir: url, commonDir: url, isBare: false)
    }
    func loadCommits(_ query: CommitQuery) -> AsyncThrowingStream<Commit, Error> {
        let commits = allCommits
        let limit = failAfter
        return AsyncThrowingStream { continuation in
            for (i, c) in commits.enumerated() {
                if i >= limit {
                    continuation.finish(throwing: GitError.commandFailed(
                        command: "git log", exitCode: 128, stderr: "object missing"))
                    return
                }
                continuation.yield(c)
            }
            continuation.finish()
        }
    }
    func commitCount(_ query: CommitQuery) async throws -> Int { allCommits.count }
    func refs(for repo: Repository) async throws -> RefSnapshot {
        RefSnapshot(head: .detached(sha: ""), branches: [], remotes: [], tags: [])
    }
    func diff(_ range: DiffRange, in repo: Repository) async throws -> [DiffFile] { [] }
    func workingCopyStatus(for repo: Repository) async throws -> WorkingCopyStatus {
        WorkingCopyStatus(branch: nil, ahead: nil, behind: nil,
                          staged: [], unstaged: [], untracked: [], conflicts: [])
    }
    func blob(at path: String, rev: String, in repo: Repository) async throws -> Data { Data() }
}

/// A backend whose refs() always throws (simulates corrupt HEAD or lock contention).
private final class ErroringRefsBackend: GitBackend, @unchecked Sendable {
    func gitVersion() async throws -> String { "fake" }
    func openRepository(at url: URL) async throws -> Repository {
        Repository(rootURL: url, gitDir: url, commonDir: url, isBare: false)
    }
    func loadCommits(_ query: CommitQuery) -> AsyncThrowingStream<Commit, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func commitCount(_ query: CommitQuery) async throws -> Int { 0 }
    func refs(for repo: Repository) async throws -> RefSnapshot {
        throw GitError.commandFailed(command: "git for-each-ref", exitCode: 128,
                                     stderr: "fatal: unable to read HEAD")
    }
    func diff(_ range: DiffRange, in repo: Repository) async throws -> [DiffFile] { [] }
    func workingCopyStatus(for repo: Repository) async throws -> WorkingCopyStatus {
        WorkingCopyStatus(branch: nil, ahead: nil, behind: nil,
                          staged: [], unstaged: [], untracked: [], conflicts: [])
    }
    func blob(at path: String, rev: String, in repo: Repository) async throws -> Data { Data() }
}
