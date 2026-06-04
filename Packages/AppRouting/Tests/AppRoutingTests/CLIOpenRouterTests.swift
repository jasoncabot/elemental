import XCTest
@testable import AppRouting

final class CLIOpenRouterTests: XCTestCase {

    // MARK: - Empty / not-ready

    func testEmptyURLsIsANoop() {
        let decision = CLIOpenRouter.route(urls: [], windows: [], isReady: true)
        XCTAssertEqual(decision, .route(focus: [], openInNewWindow: []))
    }

    func testNotReadyDefersAllURLs() {
        let urls = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]
        let decision = CLIOpenRouter.route(urls: urls, windows: [], isReady: false)
        XCTAssertEqual(decision, .deferUntilReady(urls))
    }

    // MARK: - No match → new window

    func testUnknownPathOpensInNewWindow() {
        let url = URL(fileURLWithPath: "/Users/me/projects/new")
        let decision = CLIOpenRouter.route(urls: [url], windows: [], isReady: true)
        XCTAssertEqual(decision, .route(focus: [], openInNewWindow: [url]))
    }

    // MARK: - Match → focus existing window

    func testExactRepoRootFocusesItsWindow() {
        let root = "/Users/me/projects/repo"
        let url = URL(fileURLWithPath: root)
        let windows = [CLIOpenRouter.WindowSnapshot(id: 7, repoRoots: [root])]
        let decision = CLIOpenRouter.route(urls: [url], windows: windows, isReady: true)
        XCTAssertEqual(decision, .route(
            focus: [.init(windowID: 7, url: url, matchedRoot: root)],
            openInNewWindow: []
        ))
    }

    func testSubdirectoryOfKnownRepoFocusesItsWindow() {
        let root = "/Users/me/projects/repo"
        let sub = URL(fileURLWithPath: root + "/src/views")
        let windows = [CLIOpenRouter.WindowSnapshot(id: 3, repoRoots: [root])]
        let decision = CLIOpenRouter.route(urls: [sub], windows: windows, isReady: true)
        XCTAssertEqual(decision, .route(
            focus: [.init(windowID: 3, url: sub, matchedRoot: root)],
            openInNewWindow: []
        ))
    }

    func testFocusInstructionEchoesTheOriginalRepoRootString() throws {
        // Symlink case: the matched root must be the caller's *original* string (the one
        // they put into WindowSnapshot.repoRoots), not the post-canonicalization form —
        // otherwise the coordinator can't look it up in its own bookmark list.
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("router-echo-\(UUID().uuidString)",
                                                                  isDirectory: true)
        let realDir = base.appendingPathComponent("real", isDirectory: true)
        let linkDir = base.appendingPathComponent("link", isDirectory: true)
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
        defer { try? fm.removeItem(at: base) }

        let windows = [CLIOpenRouter.WindowSnapshot(id: 5, repoRoots: [realDir.path])]
        let decision = CLIOpenRouter.route(urls: [linkDir], windows: windows, isReady: true)
        guard case .route(let focus, _) = decision, let only = focus.first else {
            return XCTFail("expected one focus instruction, got \(decision)")
        }
        XCTAssertEqual(only.matchedRoot, realDir.path)
    }

    func testSiblingPathDoesNotFalselyMatch() {
        // /a/bar must not match a repo at /a/b — the trailing '/' guard is the whole point.
        let url = URL(fileURLWithPath: "/a/bar")
        let windows = [CLIOpenRouter.WindowSnapshot(id: 1, repoRoots: ["/a/b"])]
        let decision = CLIOpenRouter.route(urls: [url], windows: windows, isReady: true)
        XCTAssertEqual(decision, .route(focus: [], openInNewWindow: [url]))
    }

    // MARK: - Symlink handling

    func testSymlinkedPathMatchesItsRealRoot() throws {
        // Stand-in for the /tmp ↔ /private/tmp case: a real directory plus a symlink that
        // points at it. The bookmark store would resolve to `realDir`; the CLI may pass
        // `linkDir`. Routing must treat them as the same repo.
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString)",
                                                                  isDirectory: true)
        let realDir = base.appendingPathComponent("real", isDirectory: true)
        let linkDir = base.appendingPathComponent("link", isDirectory: true)
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
        defer { try? fm.removeItem(at: base) }

        let windows = [CLIOpenRouter.WindowSnapshot(id: 9, repoRoots: [realDir.path])]
        let decision = CLIOpenRouter.route(urls: [linkDir], windows: windows, isReady: true)
        XCTAssertEqual(decision, .route(
            focus: [.init(windowID: 9, url: linkDir, matchedRoot: realDir.path)],
            openInNewWindow: []
        ))
    }

    func testTrailingSlashDoesNotBreakMatch() {
        let root = "/Users/me/repo"
        let withSlash = URL(fileURLWithPath: root + "/")
        let windows = [CLIOpenRouter.WindowSnapshot(id: 2, repoRoots: [root])]
        let decision = CLIOpenRouter.route(urls: [withSlash], windows: windows, isReady: true)
        XCTAssertEqual(decision, .route(
            focus: [.init(windowID: 2, url: withSlash, matchedRoot: root)],
            openInNewWindow: []
        ))
    }

    // MARK: - Multi-URL routing

    func testMixedMatchedAndUnmatchedURLsSplitCorrectly() {
        let known = "/Users/me/known"
        let unknown = URL(fileURLWithPath: "/Users/me/elsewhere")
        let matched = URL(fileURLWithPath: known + "/sub")
        let windows = [CLIOpenRouter.WindowSnapshot(id: 4, repoRoots: [known])]
        let decision = CLIOpenRouter.route(urls: [matched, unknown], windows: windows, isReady: true)
        XCTAssertEqual(decision, .route(
            focus: [.init(windowID: 4, url: matched, matchedRoot: known)],
            openInNewWindow: [unknown]
        ))
    }

    func testFirstMatchingWindowWinsWhenSameRepoOpenTwice() {
        let root = "/Users/me/repo"
        let url = URL(fileURLWithPath: root)
        let windows = [
            CLIOpenRouter.WindowSnapshot(id: 1, repoRoots: [root]),
            CLIOpenRouter.WindowSnapshot(id: 2, repoRoots: [root]),
        ]
        let decision = CLIOpenRouter.route(urls: [url], windows: windows, isReady: true)
        XCTAssertEqual(decision, .route(
            focus: [.init(windowID: 1, url: url, matchedRoot: root)],
            openInNewWindow: []
        ))
    }
}
