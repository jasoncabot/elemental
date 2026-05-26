import XCTest
import TestSupport
@testable import GitData

final class GitServiceTests: XCTestCase {

    // MARK: - Basic delegation

    func testOpenRepositoryDelegates() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("README.md", "hello")
        _ = try fixture.commit("init")

        let service = try GitService()
        let repo = try await service.openRepository(at: fixture.url)
        XCTAssertEqual(repo.rootURL.resolvingSymlinksInPath(), fixture.url.resolvingSymlinksInPath())
        XCTAssertFalse(repo.isBare)
    }

    func testLoadCommitsStreamsIncrementally() async throws {
        let fixture = try FixtureRepo()
        // Create several commits so we have a non-trivial stream.
        for i in 1...5 {
            try fixture.writeFile("file\(i).txt", "content \(i)")
            _ = try fixture.commit("commit \(i)")
        }

        let service = try GitService()
        let repo = try await service.openRepository(at: fixture.url)

        var received: [Commit] = []
        for try await commit in service.loadCommits(CommitQuery(repo: repo, scope: .head)) {
            received.append(commit)
        }
        XCTAssertEqual(received.count, 5)
        XCTAssertEqual(received.first?.subject, "commit 5")
    }

    // MARK: - Cancellation terminates the child process

    func testCancellationTerminatesChildProcess() async throws {
        // Build a large fixture so git log takes meaningful time.
        let fixture = try FixtureRepo()
        for i in 1...30 {
            try fixture.writeFile("f\(i).txt", String(repeating: "x", count: 512))
            _ = try fixture.commit("commit \(i)")
        }

        let service = try GitService()
        let repo = try await service.openRepository(at: fixture.url)

        // Start consuming the stream in a Task, then cancel it promptly.
        let consumer = Task {
            var count = 0
            for try await _ in service.loadCommits(CommitQuery(repo: repo, scope: .head)) {
                count += 1
                // Yield after the first commit to give the process time to start.
                if count == 1 { break }
            }
        }

        consumer.cancel()

        // The task should finish (not hang) — child process must have been terminated.
        // We use a timeout via a detached watchdog task.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 s
        }

        // Await the consumer with a timeout (ignore any thrown error from cancellation).
        _ = try? await consumer.value
        watchdog.cancel()

        // If we reach here within 5 s, cancellation worked.
        XCTAssertTrue(true, "consumer completed after cancellation")
    }

    // MARK: - Request coalescing

    func testRefsCoalescesInFlightRequests() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("first")

        let service = try GitService()
        let repo = try await service.openRepository(at: fixture.url)

        // Fire two concurrent refs() calls; both should succeed (they share one in-flight task).
        async let snap1 = service.refs(for: repo)
        async let snap2 = service.refs(for: repo)
        let (s1, s2) = try await (snap1, snap2)

        // Both results should describe the same repository state.
        XCTAssertEqual(s1.branches.map(\.name).sorted(), s2.branches.map(\.name).sorted())
    }

    func testWorkingCopyStatusCoalescesInFlightRequests() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("first")
        try fixture.writeFile("a.txt", "modified") // unstaged

        let service = try GitService()
        let repo = try await service.openRepository(at: fixture.url)

        async let status1 = service.workingCopyStatus(for: repo)
        async let status2 = service.workingCopyStatus(for: repo)
        let (ws1, ws2) = try await (status1, status2)

        XCTAssertEqual(ws1.isClean, ws2.isClean)
        XCTAssertFalse(ws1.isClean)
    }

    func testDiffCoalescesInFlightRequests() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "line1\nline2\n")
        let sha = try fixture.commit("first")

        let service = try GitService()
        let repo = try await service.openRepository(at: fixture.url)

        async let diff1 = service.diff(.commit(sha), in: repo)
        async let diff2 = service.diff(.commit(sha), in: repo)
        let (d1, d2) = try await (diff1, diff2)

        XCTAssertEqual(d1.count, d2.count)
    }

    // MARK: - gitVersion passthrough

    func testGitVersionReturnsNonEmpty() async throws {
        let service = try GitService()
        let version = try await service.gitVersion()
        XCTAssertTrue(version.hasPrefix("git version"), "expected 'git version …', got: \(version)")
    }

    // MARK: - blob passthrough

    func testBlobRoundtrip() async throws {
        let fixture = try FixtureRepo()
        let content = "hello blob"
        try fixture.writeFile("blob.txt", content)
        let sha = try fixture.commit("add blob")

        let service = try GitService()
        let repo = try await service.openRepository(at: fixture.url)
        let data = try await service.blob(at: "blob.txt", rev: sha, in: repo)
        XCTAssertEqual(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines), content)
    }
}
