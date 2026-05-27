import XCTest
import GitData
@testable import Presenters

@MainActor
final class SidebarPresenterTests: XCTestCase {

    private func makeRepo(path: String = "/tmp/repo") -> Repository {
        Repository(rootURL: URL(fileURLWithPath: path),
                   gitDir: URL(fileURLWithPath: path + "/.git"),
                   commonDir: URL(fileURLWithPath: path + "/.git"), isBare: false)
    }

    private func makeRef(_ name: String, sha: String, kind: RefKind) -> Ref {
        Ref(name: name, sha: sha, kind: kind)
    }

    // MARK: – Ref grouping

    func testRefsGroupedByKind() async throws {
        let backend = FakeBackend()
        backend.stubbedRefs = RefSnapshot(
            head: .detached(sha: "abc"),
            branches: [makeRef("main", sha: "abc", kind: .branch),
                       makeRef("dev",  sha: "def", kind: .branch)],
            remotes:  [makeRef("origin/main", sha: "abc", kind: .remote)],
            tags:     [makeRef("v1.0", sha: "abc", kind: .tag)]
        )
        let presenter = SidebarPresenter(backend: backend, watcher: FakeWatcher())
        let repo = makeRepo()
        presenter.setRepositories([repo])

        try await Task.sleep(for: .milliseconds(50))

        let item = try XCTUnwrap(presenter.items.first)
        XCTAssertEqual(item.branches.count, 2)
        XCTAssertEqual(item.remotes.count, 1)
        XCTAssertEqual(item.tags.count, 1)
    }

    func testRefsLoadedAfterSetRepositories() async throws {
        let backend = FakeBackend()
        backend.stubbedRefs = RefSnapshot(
            head: .attached(branch: "main", sha: "abc"),
            branches: [makeRef("main", sha: "abc", kind: .branch)],
            remotes: [], tags: []
        )
        let presenter = SidebarPresenter(backend: backend, watcher: FakeWatcher())
        presenter.setRepositories([makeRepo()])

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(presenter.items.isEmpty)
        XCTAssertNotNil(presenter.items.first?.refs)
        XCTAssertFalse(presenter.items.first?.isLoadingRefs ?? true)
    }

    // MARK: – Selection

    func testSelectionIsPropagated() async throws {
        let backend = FakeBackend()
        let presenter = SidebarPresenter(backend: backend, watcher: FakeWatcher())
        let repo = makeRepo()
        presenter.setRepositories([repo])

        presenter.select(.branch(repo, "main"))
        XCTAssertEqual(presenter.selection, .allCommits(repo) == presenter.selection ? nil : presenter.selection)
        if case .branch(let r, let name) = presenter.selection {
            XCTAssertEqual(r.rootURL, repo.rootURL)
            XCTAssertEqual(name, "main")
        } else {
            XCTFail("Expected branch selection")
        }
    }

    func testSelectionClearedWhenRepoRemoved() async throws {
        let backend = FakeBackend()
        let presenter = SidebarPresenter(backend: backend, watcher: FakeWatcher())
        let repo = makeRepo()
        presenter.setRepositories([repo])
        presenter.select(.allCommits(repo))
        XCTAssertNotNil(presenter.selection)

        // Remove the repo.
        presenter.setRepositories([])
        XCTAssertNil(presenter.selection)
    }

    // MARK: – Dirty / Refresh

    func testDirtyEventSetsFlag() async throws {
        let watcher = FakeWatcher()
        let presenter = SidebarPresenter(backend: FakeBackend(), watcher: watcher)
        let repo = makeRepo()
        presenter.setRepositories([repo])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(presenter.isDirty)

        watcher.fire(DirtyEvent(repo: repo, changedPaths: ["HEAD"]))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(presenter.isDirty)
        // Refs not reloaded: items still have whatever was loaded on start.
    }

    func testRefreshClearsDirtyAndReloadsRefs() async throws {
        let backend = FakeBackend()
        let watcher = FakeWatcher()
        let presenter = SidebarPresenter(backend: backend, watcher: watcher)
        let repo = makeRepo()
        presenter.setRepositories([repo])
        try await Task.sleep(for: .milliseconds(20))

        watcher.fire(DirtyEvent(repo: repo, changedPaths: ["HEAD"]))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(presenter.isDirty)

        backend.stubbedRefs = RefSnapshot(
            head: .attached(branch: "new-branch", sha: "xyz"),
            branches: [makeRef("new-branch", sha: "xyz", kind: .branch)],
            remotes: [], tags: []
        )
        presenter.refresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(presenter.isDirty)
        XCTAssertEqual(presenter.items.first?.branches.count, 1)
        XCTAssertEqual(presenter.items.first?.branches.first?.name, "new-branch")
    }
}
