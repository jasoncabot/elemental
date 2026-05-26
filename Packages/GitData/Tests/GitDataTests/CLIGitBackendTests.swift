import XCTest
import TestSupport
@testable import GitData

final class CLIGitBackendTests: XCTestCase {
    private func makeBackend() throws -> CLIGitBackend {
        try CLIGitBackend()
    }

    func testOpenRepositoryResolvesRoot() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("README.md", "hello")
        _ = try fixture.commit("init")
        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        XCTAssertEqual(repo.rootURL.resolvingSymlinksInPath(), fixture.url.resolvingSymlinksInPath())
        XCTAssertFalse(repo.isBare)
    }

    func testOpenNonRepositoryThrows() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let backend = try makeBackend()
        do {
            _ = try await backend.openRepository(at: tmp)
            XCTFail("expected notARepository")
        } catch is GitError {
            // expected
        }
    }

    func testLoadCommitsReturnsHistoryNewestFirst() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        let first = try fixture.commit("first")
        try fixture.writeFile("a.txt", "2")
        let second = try fixture.commit("second")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        var commits: [Commit] = []
        for try await commit in backend.loadCommits(CommitQuery(repo: repo, scope: .head)) {
            commits.append(commit)
        }
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].sha, second)
        XCTAssertEqual(commits[1].sha, first)
        XCTAssertEqual(commits[0].subject, "second")
        XCTAssertEqual(commits[0].parents, [first])
        XCTAssertEqual(commits[0].author.email, "fixture@example.com")
    }

    func testRefsReportsBranchesAndHead() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("first")
        try fixture.checkoutNewBranch("feature")
        try fixture.writeFile("b.txt", "2")
        _ = try fixture.commit("feature work")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        let names = Set(snapshot.branches.map(\.name))
        XCTAssertTrue(names.contains("main"))
        XCTAssertTrue(names.contains("feature"))
        if case .attached(let branch, _) = snapshot.head {
            XCTAssertEqual(branch, "feature")
        } else {
            XCTFail("expected attached HEAD")
        }
    }

    func testDiffForCommitParsesHunks() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "line1\nline2\n")
        _ = try fixture.commit("first")
        try fixture.writeFile("a.txt", "line1\nline2 changed\nline3\n")
        let second = try fixture.commit("second")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let files = try await backend.diff(.commit(second), in: repo)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.displayPath, "a.txt")
        XCTAssertFalse(file.hunks.isEmpty)
        XCTAssertGreaterThan(file.additions, 0)
    }

    func testWorkingCopyStatusReportsStagedAndUnstaged() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("first")
        try fixture.writeFile("a.txt", "modified")      // unstaged
        try fixture.writeFile("new.txt", "new")          // untracked
        try fixture.run(["add", "new.txt"])              // staged

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let status = try await backend.workingCopyStatus(for: repo)
        XCTAssertFalse(status.isClean)
        XCTAssertTrue(status.staged.contains { $0.path == "new.txt" })
        XCTAssertTrue(status.unstaged.contains { $0.path == "a.txt" })
    }

    func testResilientToOnDiskChangeForKnownSha() async throws {
        // Loading a commit by SHA must keep working even after refs move underneath us.
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        let first = try fixture.commit("first")
        try fixture.writeFile("a.txt", "2")
        _ = try fixture.commit("second")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)

        // Simulate a CLI branch switch happening underneath the app.
        try fixture.checkout(first)

        // The previously-known SHA is still resolvable; no throw.
        let files = try await backend.diff(.commit(first), in: repo)
        XCTAssertNotNil(files)
    }
}
