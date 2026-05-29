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
        await awaitCondition(on: presenter) { presenter.commits.count == 2 }
        XCTAssertEqual(presenter.selectedSHA, "b")
    }

    func testDirtyEventDoesNotReloadButSetsFlag() async throws {
        let backend = FakeBackend()
        backend.commitsByScopeAll = [makeCommit("b"), makeCommit("a")]
        let watcher = FakeWatcher()
        let presenter = TimelinePresenter(backend: backend, watcher: watcher, repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }
        XCTAssertFalse(presenter.isDirty)

        watcher.fire(DirtyEvent(repo: repo(), changedPaths: ["HEAD"]))
        await awaitCondition(on: presenter) { presenter.isDirty }
        // Commits unchanged (no auto-reload): still showing the original snapshot.
        XCTAssertEqual(presenter.commits.count, 2)
    }

    func testRefreshPreservesSelectionWhenShaSurvives() async throws {
        let backend = FakeBackend()
        backend.commitsByScopeAll = [makeCommit("b"), makeCommit("a")]
        let presenter = TimelinePresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }
        presenter.select("a")
        presenter.refresh()
        await awaitCondition(on: presenter) { !presenter.isLoading }
        XCTAssertEqual(presenter.selectedSHA, "a")
        XCTAssertFalse(presenter.isDirty)
    }

    func testRefreshFallsBackWhenSelectedShaRemoved() async throws {
        let backend = FakeBackend()
        backend.commitsByScopeAll = [makeCommit("b"), makeCommit("a")]
        let presenter = TimelinePresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoading }
        presenter.select("a")
        // Simulate a squash: "a" is gone after refresh.
        backend.commitsByScopeAll = [makeCommit("c")]
        presenter.refresh()
        await awaitCondition(on: presenter) { !presenter.isLoading }
        XCTAssertEqual(presenter.selectedSHA, "c") // graceful fallback, no crash
    }

    func testCommitDetailCachesDiffPerSha() async throws {
        let backend = FakeBackend()
        backend.diffsBySHA["b"] = [DiffFile(oldPath: "a", newPath: "a", status: .modified,
                                            isBinary: false, hunks: [], additions: 1, deletions: 0)]
        let presenter = CommitDetailPresenter(backend: backend, repo: repo())
        presenter.show(commit: makeCommit("b"))
        await awaitCondition(on: presenter) { !presenter.files.isEmpty }
        XCTAssertEqual(presenter.files.count, 1)
        XCTAssertEqual(backend.diffCallCount, 1)

        presenter.show(commit: nil)
        presenter.show(commit: makeCommit("b"))   // served from cache
        await awaitCondition(on: presenter) { !presenter.files.isEmpty }
        XCTAssertEqual(backend.diffCallCount, 1)
    }
}
