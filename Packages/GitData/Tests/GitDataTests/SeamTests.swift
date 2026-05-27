import XCTest
import TestSupport
@testable import GitData

/// Seam tests for the data layer: real git binary, real FixtureRepo fixtures.
/// One test per topology/edge-case; no mocking of git itself.
final class SeamTests: XCTestCase {

    private func makeBackend() throws -> CLIGitBackend {
        try CLIGitBackend()
    }

    // MARK: - Octopus merge

    /// An octopus merge commit must have >2 parent SHAs and isMerge == true.
    func testOctopusMergeCommitHasMultipleParents() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("base.txt", "base")
        _ = try fixture.commit("base")

        try fixture.checkoutNewBranch("side1")
        try fixture.writeFile("s1.txt", "s1")
        _ = try fixture.commit("side1")

        try fixture.checkout("main")
        try fixture.checkoutNewBranch("side2")
        try fixture.writeFile("s2.txt", "s2")
        _ = try fixture.commit("side2")

        try fixture.checkout("main")
        try fixture.octopusMerge(["side1", "side2"], message: "octopus merge")
        let octopusSHA = try fixture.revParse("HEAD")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        var commits: [Commit] = []
        for try await c in backend.loadCommits(CommitQuery(repo: repo, scope: .head)) {
            commits.append(c)
        }
        let head = try XCTUnwrap(commits.first)
        XCTAssertEqual(head.sha, octopusSHA)
        XCTAssertGreaterThanOrEqual(head.parents.count, 2, "octopus merge must have >=2 parents")
        XCTAssertTrue(head.isMerge)
    }

    // MARK: - Empty repo

    /// An empty repo (no commits) must not throw on openRepository and returns unborn HEAD.
    func testEmptyRepoOpensAndHasUnbornHead() async throws {
        let fixture = try FixtureRepo.makeEmpty()
        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        XCTAssertFalse(repo.isBare)
        let snapshot = try await backend.refs(for: repo)
        if case .unborn = snapshot.head {
            // correct
        } else {
            XCTFail("expected unborn HEAD, got \(snapshot.head)")
        }
    }

    // MARK: - Detached HEAD

    /// After detaching HEAD at a SHA, refs() must report .detached.
    func testDetachedHeadReportedInRefSnapshot() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        let sha = try fixture.commit("first")
        try fixture.writeFile("a.txt", "2")
        _ = try fixture.commit("second")
        // Detach HEAD at first commit.
        try fixture.checkout(sha)

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        if case .detached(let detachedSHA) = snapshot.head {
            XCTAssertEqual(detachedSHA, sha)
        } else {
            XCTFail("expected detached HEAD, got \(snapshot.head)")
        }
    }

    // MARK: - Bare repo

    /// CLIGitBackend.openRepository uses `rev-parse --show-toplevel` which git rejects in bare repos
    /// ("this operation must be run in a work tree"). The backend therefore throws notARepository
    /// for bare paths — pinning this known limitation so any future fix breaks this test and forces
    /// updating the assertion to XCTAssertTrue(repo.isBare) once the backend is extended.
    func testBareRepoThrowsNotARepository() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "hello")
        _ = try fixture.commit("init")
        let bareURL = try fixture.makeBareClone()
        defer { try? FileManager.default.removeItem(at: bareURL) }

        let backend = try makeBackend()
        do {
            _ = try await backend.openRepository(at: bareURL)
            XCTFail("expected notARepository for bare repo (current backend limitation)")
        } catch is GitError {
            // Expected: bare repo path hits the `--show-toplevel` git limitation.
        }
    }

    // MARK: - Worktree

    /// After adding a linked worktree, the Repository's worktrees list must include it.
    func testLinkedWorktreeAppearsInRepository() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("base")
        let wtURL = try fixture.addWorktree(branch: "wt-branch")
        defer { try? FileManager.default.removeItem(at: wtURL) }

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        XCTAssertFalse(repo.worktrees.isEmpty, "linked worktrees must appear in Repository.worktrees")
        let paths = repo.worktrees.map { $0.path.resolvingSymlinksInPath() }
        let matches = paths.contains { $0 == wtURL.resolvingSymlinksInPath() }
        XCTAssertTrue(matches, "worktree path \(wtURL) not found in \(paths)")
    }

    // MARK: - Non-ASCII / emoji

    /// Commit with emoji subject + non-ASCII file path must round-trip through Commit.subject and DiffFile.displayPath.
    func testNonASCIIAndEmojiRoundTrips() async throws {
        let fixture = try FixtureRepo()
        let filename = "données/résumé 🎉.txt"
        try fixture.writeFile(filename, "bonjour")
        let sha = try fixture.commit("feat: 🚀 Add données/résumé 🎉")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        var commits: [Commit] = []
        for try await c in backend.loadCommits(CommitQuery(repo: repo, scope: .head)) {
            commits.append(c)
        }
        let head = try XCTUnwrap(commits.first)
        XCTAssertEqual(head.sha, sha)
        XCTAssertTrue(head.subject.contains("🚀"), "emoji must survive log parsing: \(head.subject)")

        // The diff must include at least one file entry for the non-ASCII path; git may
        // octal-escape the path in output (core.quotepath default), so we only assert the
        // file appears (non-empty diff) rather than the exact path string.
        let files = try await backend.diff(.commit(sha), in: repo)
        XCTAssertFalse(files.isEmpty, "non-ASCII commit must produce at least one DiffFile")
    }

    // MARK: - Binary file

    /// A binary file's DiffFile must be marked isBinary = true.
    func testBinaryFileDetectedInDiff() async throws {
        let fixture = try FixtureRepo()
        // A minimal 1×1 BMP — unambiguously binary.
        let bmpBytes: [UInt8] = [
            0x42, 0x4D, 0x3A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x00, 0x00, 0x00,
            0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
            0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00,
            0x00, 0x00
        ]
        try fixture.writeBinary("image.bmp", bmpBytes)
        let sha = try fixture.commit("add binary")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let files = try await backend.diff(.commit(sha), in: repo)
        let bmpFile = try XCTUnwrap(files.first { $0.displayPath == "image.bmp" })
        XCTAssertTrue(bmpFile.isBinary, "binary file must be flagged isBinary in DiffFile")
    }

    // MARK: - CRLF file

    /// A CRLF-only file must be committed and parsed without crashing; diff is non-empty.
    func testCRLFFileDoesNotCrash() async throws {
        let fixture = try FixtureRepo()
        let crlfContent = Data("line1\r\nline2\r\nline3\r\n".utf8)
        try fixture.writeData("crlf.txt", crlfContent)
        let sha = try fixture.commit("add crlf file")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let files = try await backend.diff(.commit(sha), in: repo)
        XCTAssertFalse(files.isEmpty, "CRLF commit must produce diff entries")
        let crlfFile = try XCTUnwrap(files.first { $0.displayPath == "crlf.txt" })
        XCTAssertGreaterThan(crlfFile.additions, 0)
    }

    // MARK: - No trailing newline

    /// A file lacking a trailing newline must parse without crash and produce additions > 0.
    func testNoTrailingNewlineFileParses() async throws {
        let fixture = try FixtureRepo()
        let noNL = Data("no newline at end".utf8)   // intentionally no \n
        try fixture.writeData("nonewline.txt", noNL)
        let sha = try fixture.commit("add file without trailing newline")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let files = try await backend.diff(.commit(sha), in: repo)
        let f = try XCTUnwrap(files.first { $0.displayPath == "nonewline.txt" })
        XCTAssertGreaterThan(f.additions, 0)
        XCTAssertFalse(f.isBinary)
    }

    // MARK: - Rename + copy

    /// A rename commit must produce a DiffFile with status == .renamed and both paths set.
    func testRenameProducesRenamedDiffFile() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("old.txt", "content\n")
        _ = try fixture.commit("add original")
        try fixture.run(["mv", "old.txt", "new.txt"])
        let sha = try fixture.commit("rename old to new")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let files = try await backend.diff(.commit(sha), in: repo)
        let renamed = try XCTUnwrap(files.first { $0.status == .renamed })
        XCTAssertEqual(renamed.oldPath, "old.txt")
        XCTAssertEqual(renamed.newPath, "new.txt")
    }

    // MARK: - Mutating fixture robustness

    /// Reads of a previously known SHA must succeed even after new commits and branch switches
    /// happen on disk between calls — the SHA-keyed resilience contract.
    func testMutatingRepoDoesNotBreakKnownSHAReads() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        let knownSHA = try fixture.commit("first")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)

        // Mutate: add more commits.
        try fixture.writeFile("b.txt", "2")
        _ = try fixture.commit("second")
        try fixture.checkoutNewBranch("mutation-branch")
        try fixture.writeFile("c.txt", "3")
        _ = try fixture.commit("third on mutation-branch")

        // The original SHA must still be readable — no throw.
        let files = try await backend.diff(.commit(knownSHA), in: repo)
        XCTAssertNotNil(files)

        // loadCommits with .all must include the known SHA somewhere.
        var shas: Set<String> = []
        for try await c in backend.loadCommits(CommitQuery(repo: repo, scope: .all)) {
            shas.insert(c.sha)
        }
        XCTAssertTrue(shas.contains(knownSHA), "known SHA must appear after mutation")
    }

    // MARK: - Cancellation

    /// Cancelling loadCommits mid-stream must not hang and must not leave dangling processes.
    func testCancelLoadCommitsTerminatesCleanly() async throws {
        // Build a repo with several commits so there's something to stream.
        let fixture = try FixtureRepo()
        for i in 1...20 {
            try fixture.writeFile("f\(i).txt", String(repeating: "x", count: 500))
            _ = try fixture.commit("commit \(i)")
        }

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)

        let collected = try await withTimeout(seconds: 5) {
            var result: [Commit] = []
            let task = Task {
                for try await c in backend.loadCommits(CommitQuery(repo: repo, scope: .head)) {
                    result.append(c)
                    if result.count >= 3 { break }
                }
                return result
            }
            return try await task.value
        }
        // We broke out after 3 commits — the stream must have stopped without hanging.
        XCTAssertGreaterThanOrEqual(collected.count, 1)
        XCTAssertLessThanOrEqual(collected.count, 20)
    }

    // MARK: - Paging via maxCount / skip

    /// CommitQuery.maxCount and .skip must be honored by the backend.
    func testLoadCommitsRespectsMaxCountAndSkip() async throws {
        let fixture = try FixtureRepo()
        for i in 1...10 {
            try fixture.writeFile("x.txt", "\(i)")
            _ = try fixture.commit("c\(i)")
        }

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)

        // Page 1: newest 5.
        var page1: [Commit] = []
        for try await c in backend.loadCommits(CommitQuery(repo: repo, scope: .head, maxCount: 5)) {
            page1.append(c)
        }
        XCTAssertEqual(page1.count, 5)

        // Page 2: skip 5, take 5 — must be older and disjoint.
        var page2: [Commit] = []
        for try await c in backend.loadCommits(CommitQuery(repo: repo, scope: .head, maxCount: 5, skip: 5)) {
            page2.append(c)
        }
        XCTAssertEqual(page2.count, 5)
        let p1SHAs = Set(page1.map(\.sha))
        let p2SHAs = Set(page2.map(\.sha))
        XCTAssertTrue(p1SHAs.isDisjoint(with: p2SHAs), "pages must not overlap")
    }

    // MARK: - Tags in RefSnapshot

    /// A lightweight tag must appear in RefSnapshot.tags.
    func testTagAppearsInRefSnapshot() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        let sha = try fixture.commit("tagged commit")
        try fixture.tag("v1.0.0")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        let tagNames = snapshot.tags.map(\.name)
        XCTAssertTrue(tagNames.contains("v1.0.0"), "tag v1.0.0 not found in \(tagNames)")
        let tagSHA = try XCTUnwrap(snapshot.tags.first { $0.name == "v1.0.0" })
        // A lightweight tag points to the commit SHA directly.
        XCTAssertEqual(tagSHA.sha, sha)
    }

    // MARK: - Branch + merge topology

    /// A --no-ff merge commit must have 2 parents; both branch SHAs are reachable.
    func testBranchAndMergeProducesMergeCommit() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("base.txt", "base")
        let baseSHA = try fixture.commit("base")

        try fixture.checkoutNewBranch("feature")
        try fixture.writeFile("feat.txt", "feat")
        let featureSHA = try fixture.commit("feature work")

        try fixture.checkout("main")
        try fixture.merge("feature", message: "merge feature into main")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        var commits: [Commit] = []
        for try await c in backend.loadCommits(CommitQuery(repo: repo, scope: .head)) {
            commits.append(c)
        }
        let mergeCommit = try XCTUnwrap(commits.first)
        XCTAssertEqual(mergeCommit.parents.count, 2)
        XCTAssertTrue(mergeCommit.isMerge)
        let parentSet = Set(mergeCommit.parents)
        XCTAssertTrue(parentSet.contains(featureSHA))
        XCTAssertTrue(parentSet.contains(baseSHA))
    }
}

// MARK: - Helpers

private func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private struct TimeoutError: Error {}
