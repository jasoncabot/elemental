import XCTest
import GitData
@testable import Presenters

@MainActor
final class PresenterTests: XCTestCase {
    final class Spy: PresenterObserving {
        var updates = 0
        func presenterDidUpdate(_ presenter: AnyObject) { updates += 1 }
    }

    private func repo() -> Repository {
        Repository(rootURL: URL(fileURLWithPath: "/tmp/x"),
                   gitDir: URL(fileURLWithPath: "/tmp/x/.git"),
                   commonDir: URL(fileURLWithPath: "/tmp/x/.git"), isBare: false)
    }

    func testTimelineLoadsAndSelectsFirst() async throws {
        let backend = FakeBackend()
        backend.commitsByScopeAll = [makeCommit("b", parents: ["a"]), makeCommit("a")]
        let presenter = TimelinePresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presenter.commits.count, 2)
        XCTAssertEqual(presenter.selectedSHA, "b")
    }

    func testDirtyEventDoesNotReloadButSetsFlag() async throws {
        let backend = FakeBackend()
        backend.commitsByScopeAll = [makeCommit("b"), makeCommit("a")]
        let watcher = FakeWatcher()
        let presenter = TimelinePresenter(backend: backend, watcher: watcher, repo: repo())
        presenter.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(presenter.isDirty)

        watcher.fire(DirtyEvent(repo: repo(), changedPaths: ["HEAD"]))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(presenter.isDirty)
        // Commits unchanged (no auto-reload): still showing the original snapshot.
        XCTAssertEqual(presenter.commits.count, 2)
    }

    func testRefreshPreservesSelectionWhenShaSurvives() async throws {
        let backend = FakeBackend()
        backend.commitsByScopeAll = [makeCommit("b"), makeCommit("a")]
        let presenter = TimelinePresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        try await Task.sleep(for: .milliseconds(50))
        presenter.select("a")
        presenter.refresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presenter.selectedSHA, "a")
        XCTAssertFalse(presenter.isDirty)
    }

    func testRefreshFallsBackWhenSelectedShaRemoved() async throws {
        let backend = FakeBackend()
        backend.commitsByScopeAll = [makeCommit("b"), makeCommit("a")]
        let presenter = TimelinePresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        try await Task.sleep(for: .milliseconds(50))
        presenter.select("a")
        // Simulate a squash: "a" is gone after refresh.
        backend.commitsByScopeAll = [makeCommit("c")]
        presenter.refresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presenter.selectedSHA, "c") // graceful fallback, no crash
    }

    func testCommitDetailCachesDiffPerSha() async throws {
        let backend = FakeBackend()
        backend.diffsBySHA["b"] = [DiffFile(oldPath: "a", newPath: "a", status: .modified,
                                            isBinary: false, hunks: [], additions: 1, deletions: 0)]
        let presenter = CommitDetailPresenter(backend: backend, repo: repo())
        presenter.show(commit: makeCommit("b"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presenter.files.count, 1)
        XCTAssertEqual(backend.diffCallCount, 1)

        presenter.show(commit: nil)
        presenter.show(commit: makeCommit("b"))   // served from cache
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(backend.diffCallCount, 1)
    }
}
