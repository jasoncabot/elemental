import XCTest
import GitData
@testable import Presenters

@MainActor
final class WorkingCopyPresenterTests: XCTestCase {

    private func repo() -> Repository {
        Repository(rootURL: URL(fileURLWithPath: "/tmp/wc"),
                   gitDir: URL(fileURLWithPath: "/tmp/wc/.git"),
                   commonDir: URL(fileURLWithPath: "/tmp/wc/.git"), isBare: false)
    }

    private func makeDiffFile(_ path: String) -> DiffFile {
        DiffFile(oldPath: path, newPath: path, status: .modified,
                 isBinary: false, hunks: [], additions: 1, deletions: 0)
    }

    private func makeFileStatus(_ path: String, status: DiffStatus = .modified) -> FileStatus {
        FileStatus(path: path, status: status)
    }

    // MARK: – Status loading

    func testStatusLoadedOnStart() async throws {
        let backend = FakeBackend()
        backend.stubbedStatus = WorkingCopyStatus(
            branch: "main", ahead: 0, behind: 0,
            staged: [makeFileStatus("a.swift")],
            unstaged: [makeFileStatus("b.swift")],
            untracked: [], conflicts: []
        )
        let presenter = WorkingCopyPresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { presenter.status != nil && !presenter.isLoadingStatus }

        XCTAssertNotNil(presenter.status)
        XCTAssertEqual(presenter.status?.staged.count, 1)
        XCTAssertEqual(presenter.status?.unstaged.count, 1)
        XCTAssertFalse(presenter.isLoadingStatus)
    }

    // MARK: – Diff loading (staged vs unstaged)

    func testStagedDiffLoads() async throws {
        let backend = FakeBackend()
        backend.stagedDiffs = [makeDiffFile("staged.swift")]
        let presenter = WorkingCopyPresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoadingStatus }

        presenter.selectFile(id: "staged.swift", area: .workingStaged)
        await awaitCondition(on: presenter) { !presenter.isLoadingDiff }

        XCTAssertEqual(presenter.diff.count, 1)
        XCTAssertEqual(presenter.diff.first?.displayPath, "staged.swift")
        if case .workingStaged = presenter.selectedArea { } else { XCTFail("Expected workingStaged area") }
        XCTAssertFalse(presenter.isLoadingDiff)
    }

    func testUnstagedDiffLoads() async throws {
        let backend = FakeBackend()
        backend.unstagedDiffs = [makeDiffFile("unstaged.swift")]
        let presenter = WorkingCopyPresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoadingStatus }

        presenter.selectFile(id: "unstaged.swift", area: .workingUnstaged)
        await awaitCondition(on: presenter) { !presenter.isLoadingDiff }

        XCTAssertEqual(presenter.diff.count, 1)
        XCTAssertEqual(presenter.diff.first?.displayPath, "unstaged.swift")
        if case .workingUnstaged = presenter.selectedArea { } else { XCTFail("Expected workingUnstaged area") }
    }

    func testUntrackedSelectionLoadsContents() async throws {
        let backend = FakeBackend()
        backend.stubbedStatus = WorkingCopyStatus(
            branch: nil, ahead: nil, behind: nil,
            staged: [], unstaged: [],
            untracked: [makeFileStatus("new.txt", status: .untracked)], conflicts: [])
        backend.untrackedDiffs = ["new.txt": [makeDiffFile("new.txt")]]
        let presenter = WorkingCopyPresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoadingStatus }

        presenter.selectFile(id: "new.txt", area: .workingUntracked("new.txt"))
        await awaitCondition(on: presenter) { !presenter.isLoadingDiff && presenter.diff.count == 1 }

        XCTAssertEqual(presenter.selectedDiffFile?.displayPath, "new.txt")
        if case .workingUntracked = presenter.selectedArea { } else { XCTFail("Expected untracked area") }
    }

    func testStagedAndUnstagedSamePathSelectableIndependently() async throws {
        // The same path can be both staged and unstaged; selecting each area shows its own diff.
        let backend = FakeBackend()
        backend.stubbedStatus = WorkingCopyStatus(
            branch: nil, ahead: nil, behind: nil,
            staged: [makeFileStatus("a.swift")], unstaged: [makeFileStatus("a.swift")],
            untracked: [], conflicts: [])
        backend.stagedDiffs = [makeDiffFile("a.swift")]
        backend.unstagedDiffs = [makeDiffFile("a.swift"), makeDiffFile("b.swift")]
        let presenter = WorkingCopyPresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) {
            !presenter.stagedFiles.isEmpty && !presenter.unstagedFiles.isEmpty
        }

        presenter.selectFile(id: "a.swift", area: .workingStaged)
        await awaitCondition(on: presenter) { presenter.diff.count == 1 }
        XCTAssertEqual(presenter.diff.count, 1)

        presenter.selectFile(id: "a.swift", area: .workingUnstaged)
        await awaitCondition(on: presenter) { presenter.diff.count == 2 }
        XCTAssertEqual(presenter.diff.count, 2)
    }

    func testPreparedMessageLoadsOnStart() async throws {
        let backend = FakeBackend()
        backend.stubbedPreparedMessage = "Merge branch 'feature'"
        let presenter = WorkingCopyPresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { presenter.preparedMessage != nil }
        XCTAssertEqual(presenter.preparedMessage, "Merge branch 'feature'")
    }

    func testModeToggle() async throws {
        let backend = FakeBackend()
        let presenter = WorkingCopyPresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        XCTAssertEqual(presenter.mode, .unified)
        presenter.setMode(.sideBySide)
        XCTAssertEqual(presenter.mode, .sideBySide)
    }

    func testSelectingNilFileClearsDiff() async throws {
        let backend = FakeBackend()
        backend.stagedDiffs = [makeDiffFile("a.swift")]
        let presenter = WorkingCopyPresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoadingStatus }
        presenter.selectFile(id: "a.swift", area: .workingStaged)
        await awaitCondition(on: presenter) { !presenter.isLoadingDiff && !presenter.diff.isEmpty }

        presenter.selectFile(id: nil, area: nil)
        XCTAssertTrue(presenter.diff.isEmpty)
        XCTAssertNil(presenter.selectedFile)
    }

    // MARK: – Dirty / Refresh

    func testDirtyEventSetsIsDirtyWithoutReloading() async throws {
        let backend = FakeBackend()
        backend.stubbedStatus = WorkingCopyStatus(
            branch: nil, ahead: nil, behind: nil,
            staged: [makeFileStatus("a.swift")],
            unstaged: [], untracked: [], conflicts: []
        )
        let watcher = FakeWatcher()
        let presenter = WorkingCopyPresenter(backend: backend, watcher: watcher, repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { presenter.status != nil && !presenter.isLoadingStatus }
        XCTAssertFalse(presenter.isDirty)

        // Change what the backend would return (but should NOT be fetched yet).
        backend.stubbedStatus = WorkingCopyStatus(
            branch: nil, ahead: nil, behind: nil,
            staged: [], unstaged: [], untracked: [], conflicts: []
        )
        watcher.fire(DirtyEvent(repo: repo(), changedPaths: [".git/index"]))
        await awaitCondition(on: presenter) { presenter.isDirty }

        // Status not reloaded — still shows the original staged file.
        XCTAssertEqual(presenter.status?.staged.count, 1)
    }

    func testRefreshReloadsStatusAndClearsDirty() async throws {
        let backend = FakeBackend()
        backend.stubbedStatus = WorkingCopyStatus(
            branch: nil, ahead: nil, behind: nil,
            staged: [makeFileStatus("a.swift")],
            unstaged: [], untracked: [], conflicts: []
        )
        let watcher = FakeWatcher()
        let presenter = WorkingCopyPresenter(backend: backend, watcher: watcher, repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { presenter.status != nil && !presenter.isLoadingStatus }

        watcher.fire(DirtyEvent(repo: repo(), changedPaths: [".git/index"]))
        await awaitCondition(on: presenter) { presenter.isDirty }

        // After squash: staged file is gone.
        backend.stubbedStatus = WorkingCopyStatus(
            branch: nil, ahead: nil, behind: nil,
            staged: [], unstaged: [], untracked: [], conflicts: []
        )
        presenter.refresh()
        await awaitCondition(on: presenter) { !presenter.isLoadingStatus && !presenter.isDirty }

        XCTAssertFalse(presenter.isDirty)
        XCTAssertEqual(presenter.status?.staged.count, 0)
    }

    func testRefreshReloadsDiffForSelectedFile() async throws {
        let backend = FakeBackend()
        // Real git keeps `status` and `diff --cached` consistent: a staged file appears in both.
        backend.stubbedStatus = WorkingCopyStatus(
            branch: nil, ahead: nil, behind: nil,
            staged: [makeFileStatus("a.swift")], unstaged: [], untracked: [], conflicts: [])
        backend.stagedDiffs = [makeDiffFile("a.swift")]
        let presenter = WorkingCopyPresenter(backend: backend, watcher: FakeWatcher(), repo: repo())
        presenter.start()
        await awaitCondition(on: presenter) { !presenter.isLoadingStatus }
        presenter.selectFile(id: "a.swift", area: .workingStaged)
        await awaitCondition(on: presenter) { !presenter.isLoadingDiff && presenter.diff.count == 1 }

        // After refresh, the diff is reloaded with new content (status stays consistent).
        backend.stubbedStatus = WorkingCopyStatus(
            branch: nil, ahead: nil, behind: nil,
            staged: [makeFileStatus("a.swift"), makeFileStatus("b.swift")],
            unstaged: [], untracked: [], conflicts: [])
        backend.stagedDiffs = [makeDiffFile("a.swift"), makeDiffFile("b.swift")]
        presenter.refresh()
        await awaitCondition(on: presenter) { !presenter.isLoadingDiff && presenter.diff.count == 2 }
        XCTAssertEqual(presenter.diff.count, 2)
    }
}
