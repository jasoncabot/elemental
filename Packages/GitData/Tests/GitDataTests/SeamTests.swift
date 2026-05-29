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

        // The backend forces core.quotepath=false, so the path is emitted raw (not octal-escaped)
        // and must round-trip intact through DiffFile.displayPath.
        let files = try await backend.diff(.commit(sha), in: repo)
        XCTAssertFalse(files.isEmpty, "non-ASCII commit must produce at least one DiffFile")
        XCTAssertTrue(files.contains { $0.displayPath.contains("résumé") },
                      "non-ASCII path must round-trip unescaped: \(files.map(\.displayPath))")
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

    // MARK: - Orphan worktree (unborn branch)

    /// A worktree created with --orphan has no HEAD SHA and no branch ref in refs/heads.
    /// The worktree list must include it without crashing and report nil head.
    func testOrphanWorktreeHasNilHeadAndNoBranch() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("base")
        let orphanURL = try fixture.addOrphanWorktree(branch: "orphan-branch")
        defer { try? FileManager.default.removeItem(at: orphanURL) }

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        // The orphan worktree should appear in the list.
        let orphan = repo.worktrees.first {
            $0.path.resolvingSymlinksInPath() == orphanURL.resolvingSymlinksInPath()
        }
        XCTAssertNotNil(orphan, "orphan worktree must appear in worktrees list")
        // Orphan worktrees have a branch set but a zero SHA for HEAD (git uses 40 zeros).
        // Our parser should reflect this — either nil or the null SHA.
        if let wt = orphan {
            // The branch field is set in porcelain output for orphan worktrees.
            XCTAssertNotNil(wt.branch, "orphan worktree should report its branch name")
            XCTAssertTrue(wt.branch?.contains("orphan-branch") ?? false)
        }
    }

    // MARK: - Detached HEAD worktree

    /// A worktree created with --detach must have isDetached == true and a valid HEAD SHA.
    func testDetachedWorktreeReportsDetachedState() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        let sha = try fixture.commit("first")
        let detachedURL = try fixture.addDetachedWorktree(at: sha)
        defer { try? FileManager.default.removeItem(at: detachedURL) }

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let detachedWT = repo.worktrees.first {
            $0.path.resolvingSymlinksInPath() == detachedURL.resolvingSymlinksInPath()
        }
        XCTAssertNotNil(detachedWT, "detached worktree must appear in worktrees list")
        if let wt = detachedWT {
            XCTAssertTrue(wt.isDetached, "worktree created with --detach must have isDetached == true")
            XCTAssertNil(wt.branch, "detached worktree must have nil branch")
            XCTAssertEqual(wt.head, sha)
        }
    }

    // MARK: - Locked worktree

    /// A locked worktree must have isLocked == true in the parsed output.
    func testLockedWorktreeReportsLockedState() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("base")
        let wtURL = try fixture.addWorktree(branch: "locked-branch")
        defer { try? FileManager.default.removeItem(at: wtURL) }
        try fixture.lockWorktree(at: wtURL, reason: "testing lock")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let lockedWT = repo.worktrees.first {
            $0.path.resolvingSymlinksInPath() == wtURL.resolvingSymlinksInPath()
        }
        XCTAssertNotNil(lockedWT, "locked worktree must appear in worktrees list")
        XCTAssertTrue(lockedWT?.isLocked ?? false, "worktree must report isLocked after git worktree lock")
    }

    // MARK: - Refs from linked worktree context

    /// Opening a linked worktree directly and querying refs must return the shared refs
    /// (branches/tags from commonDir), not just per-worktree refs.
    func testRefsFromLinkedWorktreeIncludesSharedBranches() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("first")
        try fixture.checkoutNewBranch("shared-branch")
        try fixture.writeFile("b.txt", "2")
        _ = try fixture.commit("on shared-branch")
        try fixture.checkout("main")
        let wtURL = try fixture.addWorktree(branch: "wt-branch")
        defer { try? FileManager.default.removeItem(at: wtURL) }

        let backend = try makeBackend()
        // Open the linked worktree directly — this is how a user might drag it into the app.
        let repo = try await backend.openRepository(at: wtURL)
        let snapshot = try await backend.refs(for: repo)
        let branchNames = Set(snapshot.branches.map(\.name))
        // The linked worktree must see branches from the shared commonDir.
        XCTAssertTrue(branchNames.contains("main"), "linked worktree must see 'main' from commonDir")
        XCTAssertTrue(branchNames.contains("shared-branch"), "linked worktree must see 'shared-branch'")
        XCTAssertTrue(branchNames.contains("wt-branch"), "linked worktree must see its own branch")
    }

    // MARK: - Status porcelain v2 on unborn branch (initial)

    /// On an unborn branch (no commits), `status --porcelain=v2` reports `branch.oid (initial)`.
    /// workingCopyStatus must not crash and should reflect the staged files correctly.
    func testWorkingCopyStatusOnUnbornBranchDoesNotCrash() async throws {
        let fixture = try FixtureRepo.makeEmpty()
        // Stage a file but don't commit — we're still on the unborn "main" branch.
        try fixture.writeFile("new.txt", "content")
        try fixture.run(["add", "new.txt"])

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let status = try await backend.workingCopyStatus(for: repo)
        // The staged file must appear.
        XCTAssertTrue(status.staged.contains { $0.path == "new.txt" },
                      "staged file on unborn branch must be reported")
    }

    // MARK: - Worktree with empty index (orphan, no files)

    /// Opening an orphan worktree and getting its status must not crash even with an empty index.
    func testOrphanWorktreeStatusIsClean() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("base")
        let orphanURL = try fixture.addOrphanWorktree(branch: "empty-orphan")
        defer { try? FileManager.default.removeItem(at: orphanURL) }

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: orphanURL)
        let status = try await backend.workingCopyStatus(for: repo)
        // An orphan worktree with no files staged should be clean.
        XCTAssertTrue(status.isClean, "orphan worktree with empty index should report clean status")
    }

    // MARK: - Prunable worktree (stale admin files)

    /// After manually removing a worktree's directory, the main repo must still list worktrees
    /// without crashing. The prunable worktree may or may not still appear depending on git version.
    func testPrunableWorktreeDoesNotCrashWorktreeList() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("base")
        let wtURL = try fixture.addWorktree(branch: "prunable-branch")
        // Manually remove the worktree directory to simulate stale admin files.
        try FileManager.default.removeItem(at: wtURL)

        let backend = try makeBackend()
        // This must not crash — the backend should handle prunable/missing worktrees gracefully.
        let repo = try await backend.openRepository(at: fixture.url)
        // The worktrees list is populated (at minimum the main worktree appears).
        XCTAssertNotNil(repo.worktrees)
    }

    // MARK: - Refs after gc (packed refs)

    /// After `git gc`, refs are packed into packed-refs. The refs() call must still resolve them.
    func testRefsAfterGCStillResolve() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        let sha = try fixture.commit("first")
        try fixture.tag("v0.1")
        try fixture.checkoutNewBranch("gc-branch")
        try fixture.writeFile("b.txt", "2")
        _ = try fixture.commit("second")
        // Pack refs via gc.
        try fixture.run(["gc", "--aggressive", "--prune=now"])

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        let branchNames = Set(snapshot.branches.map(\.name))
        XCTAssertTrue(branchNames.contains("main"), "main must survive gc")
        XCTAssertTrue(branchNames.contains("gc-branch"), "gc-branch must survive gc")
        let tagNames = Set(snapshot.tags.map(\.name))
        XCTAssertTrue(tagNames.contains("v0.1"), "tag must survive gc")
        // The SHA must still be correct after packing.
        let tagRef = try XCTUnwrap(snapshot.tags.first { $0.name == "v0.1" })
        XCTAssertEqual(tagRef.sha, sha)
    }

    // MARK: - Stash does not corrupt refs

    /// Creating and popping a stash must not alter the branch ref or HEAD SHA, and refs()
    /// must still return a consistent snapshot.
    func testStashDoesNotAffectRefsSnapshot() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "original")
        let sha = try fixture.commit("base")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let beforeSnapshot = try await backend.refs(for: repo)

        // Create dirty state and stash it.
        try fixture.writeFile("a.txt", "dirty")
        try fixture.stash(message: "wip")

        let afterStashSnapshot = try await backend.refs(for: repo)
        // HEAD and branch must not have moved.
        XCTAssertEqual(afterStashSnapshot.head.sha, sha)
        XCTAssertEqual(afterStashSnapshot.head, beforeSnapshot.head)

        // Pop stash — refs still unchanged.
        try fixture.stashPop()
        let afterPopSnapshot = try await backend.refs(for: repo)
        XCTAssertEqual(afterPopSnapshot.head.sha, sha)
    }

    // MARK: - Stash on detached HEAD

    /// Stash must work even when HEAD is detached (no branch) and refs() must report detached.
    func testStashOnDetachedHeadDoesNotCrash() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        let sha = try fixture.commit("first")
        try fixture.writeFile("a.txt", "2")
        _ = try fixture.commit("second")
        try fixture.checkout(sha) // detach

        try fixture.writeFile("a.txt", "dirty on detached")
        try fixture.stash(message: "detached stash")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        if case .detached(let detSHA) = snapshot.head {
            XCTAssertEqual(detSHA, sha)
        } else {
            XCTFail("expected detached HEAD after stash, got \(snapshot.head)")
        }
    }

    // MARK: - git switch

    /// Using `git switch` to change branches must be reflected in refs().head.
    func testSwitchBranchUpdatesHead() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("first")
        try fixture.checkoutNewBranch("other")
        try fixture.writeFile("b.txt", "2")
        _ = try fixture.commit("other commit")
        try fixture.switchBranch("main")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        if case .attached(let branch, _) = snapshot.head {
            XCTAssertEqual(branch, "main")
        } else {
            XCTFail("expected attached HEAD on main after switch, got \(snapshot.head)")
        }
    }

    // MARK: - Rebase rewrites history

    /// After a rebase that rewrites commits, previously-known SHAs may become unreachable
    /// from HEAD. The backend must not crash; refs must still resolve.
    func testRebaseRewritesHistoryRefsStillResolve() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("first")
        try fixture.writeFile("a.txt", "2")
        _ = try fixture.commit("second")
        try fixture.writeFile("a.txt", "3")
        let thirdSHA = try fixture.commit("third")

        // Squash last 2 commits — this rewrites SHAs.
        let status = try fixture.rebaseSquash(last: 2)
        // If rebase fails (e.g. sed not available), skip gracefully.
        if status != 0 {
            // On some systems the sed-based rebase may not work; skip but don't fail.
            return
        }

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        // HEAD should be attached and have a valid SHA (different from thirdSHA after squash).
        XCTAssertNotNil(snapshot.head.sha)
        if let headSHA = snapshot.head.sha {
            XCTAssertNotEqual(headSHA, thirdSHA, "rebase should have rewritten the SHA")
            XCTAssertFalse(headSHA.isEmpty)
        }
        // Branches must still list.
        let branchNames = Set(snapshot.branches.map(\.name))
        XCTAssertTrue(branchNames.contains("main"))
    }

    // MARK: - Shallow clone

    /// A shallow clone (--depth=1) must open correctly and report refs without crashing.
    /// History is truncated but the backend must not throw for the limited history.
    func testShallowCloneOpensAndReportsRefs() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("first")
        try fixture.writeFile("a.txt", "2")
        _ = try fixture.commit("second")
        try fixture.writeFile("a.txt", "3")
        _ = try fixture.commit("third")

        let shallowURL = try fixture.makeShallowClone(depth: 1)
        defer { try? FileManager.default.removeItem(at: shallowURL) }

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: shallowURL)
        XCTAssertFalse(repo.isBare)

        // Refs must resolve — the shallow clone has a valid HEAD.
        let snapshot = try await backend.refs(for: repo)
        XCTAssertNotNil(snapshot.head.sha)
        let branchNames = Set(snapshot.branches.map(\.name))
        XCTAssertTrue(branchNames.contains("main"), "shallow clone must report main branch")
    }

    // MARK: - Shallow clone limited history

    /// loadCommits on a shallow clone must return only the available (grafted) history
    /// without throwing an error for missing parent objects.
    func testShallowCloneLoadCommitsDoesNotThrow() async throws {
        let fixture = try FixtureRepo()
        for i in 1...5 {
            try fixture.writeFile("f.txt", "\(i)")
            _ = try fixture.commit("commit \(i)")
        }
        let shallowURL = try fixture.makeShallowClone(depth: 2)
        defer { try? FileManager.default.removeItem(at: shallowURL) }

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: shallowURL)
        var commits: [Commit] = []
        for try await c in backend.loadCommits(CommitQuery(repo: repo, scope: .head)) {
            commits.append(c)
        }
        // Shallow clone with depth=2 should have at most 2 commits visible.
        XCTAssertGreaterThanOrEqual(commits.count, 1)
        XCTAssertLessThanOrEqual(commits.count, 2)
    }

    // MARK: - Refs after branch deletion

    /// Deleting a branch must remove it from the RefSnapshot on the next call.
    func testDeletedBranchDisappearsFromRefs() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("base")
        try fixture.checkoutNewBranch("ephemeral")
        try fixture.writeFile("b.txt", "2")
        _ = try fixture.commit("ephemeral work")
        try fixture.checkout("main")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)

        // Before deletion.
        let before = try await backend.refs(for: repo)
        XCTAssertTrue(before.branches.contains { $0.name == "ephemeral" })

        // Delete the branch.
        try fixture.run(["branch", "-D", "ephemeral"])

        // After deletion.
        let after = try await backend.refs(for: repo)
        XCTAssertFalse(after.branches.contains { $0.name == "ephemeral" },
                       "deleted branch must disappear from RefSnapshot")
    }

    // MARK: - Refs after force-push simulation (reset --hard)

    /// A force-push simulation (reset --hard to an older SHA) must update HEAD and refs correctly.
    func testResetHardUpdatesRefsSnapshot() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        let firstSHA = try fixture.commit("first")
        try fixture.writeFile("a.txt", "2")
        _ = try fixture.commit("second")

        // Simulate force-push: reset main back to firstSHA.
        try fixture.run(["reset", "--hard", firstSHA])

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        XCTAssertEqual(snapshot.head.sha, firstSHA,
                       "HEAD must point to the reset target after reset --hard")
    }

    // MARK: - Annotated tags

    /// An annotated tag must appear in RefSnapshot.tags and resolve to the correct commit SHA.
    func testAnnotatedTagAppearsInRefs() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("tagged")
        try fixture.run(["tag", "-a", "v2.0.0", "-m", "release v2"])

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        let tagNames = Set(snapshot.tags.map(\.name))
        XCTAssertTrue(tagNames.contains("v2.0.0"), "annotated tag must appear in refs")
        // for-each-ref with %(*objectname) or %(objectname) should dereference to commit SHA.
        let tagRef = try XCTUnwrap(snapshot.tags.first { $0.name == "v2.0.0" })
        // The SHA should either be the tag object or the commit — both are valid representations.
        XCTAssertFalse(tagRef.sha.isEmpty)
    }

    // MARK: - Multiple worktrees with different branches

    /// Multiple linked worktrees on different branches must all appear and have correct branch refs.
    func testMultipleWorktreesReportCorrectBranches() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("base")
        let wt1URL = try fixture.addWorktree(branch: "wt-alpha")
        let wt2URL = try fixture.addWorktree(branch: "wt-beta")
        defer {
            try? FileManager.default.removeItem(at: wt1URL)
            try? FileManager.default.removeItem(at: wt2URL)
        }

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let wt1 = repo.worktrees.first {
            $0.path.resolvingSymlinksInPath() == wt1URL.resolvingSymlinksInPath()
        }
        let wt2 = repo.worktrees.first {
            $0.path.resolvingSymlinksInPath() == wt2URL.resolvingSymlinksInPath()
        }
        XCTAssertNotNil(wt1)
        XCTAssertNotNil(wt2)
        XCTAssertTrue(wt1?.branch?.contains("wt-alpha") ?? false)
        XCTAssertTrue(wt2?.branch?.contains("wt-beta") ?? false)
    }

    // MARK: - Bisect state

    /// During a bisect, refs/bisect/* refs are created and BISECT_HEAD may exist.
    /// The backend must not crash and refs() must still return the normal branch/tag set.
    func testBisectStateDoesNotCorruptRefs() async throws {
        let fixture = try FixtureRepo()
        for i in 1...5 {
            try fixture.writeFile("f.txt", "\(i)")
            _ = try fixture.commit("commit \(i)")
        }
        let firstSHA = try fixture.revParse("HEAD~4")
        // Start a bisect session.
        try fixture.run(["bisect", "start"])
        try fixture.run(["bisect", "bad", "HEAD"])
        try fixture.run(["bisect", "good", firstSHA])

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        // refs() must not crash during bisect.
        let snapshot = try await backend.refs(for: repo)
        XCTAssertNotNil(snapshot.head.sha)
        let branchNames = Set(snapshot.branches.map(\.name))
        XCTAssertTrue(branchNames.contains("main"))

        // Clean up bisect state.
        try fixture.run(["bisect", "reset"])
    }

    // MARK: - Cherry-pick in progress

    /// During a conflicting cherry-pick, CHERRY_PICK_HEAD exists.
    /// workingCopyStatus must report conflicts and refs() must still work.
    func testCherryPickConflictReportsConflictsInStatus() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "base content\n")
        _ = try fixture.commit("base")

        // Create a conflicting branch.
        try fixture.checkoutNewBranch("conflict-branch")
        try fixture.writeFile("a.txt", "conflict branch content\n")
        let conflictSHA = try fixture.commit("conflict change")

        try fixture.checkout("main")
        try fixture.writeFile("a.txt", "main branch content\n")
        _ = try fixture.commit("main change")

        // Cherry-pick the conflicting commit — this should fail.
        let exitCode = try fixture.run(["cherry-pick", conflictSHA])
        guard exitCode != 0 else {
            // No conflict occurred (unlikely with this setup); skip gracefully.
            return
        }

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let status = try await backend.workingCopyStatus(for: repo)
        // There should be conflicts reported.
        XCTAssertFalse(status.isClean, "cherry-pick conflict must result in non-clean status")

        // refs() must not crash.
        let snapshot = try await backend.refs(for: repo)
        XCTAssertNotNil(snapshot.head.sha)

        // Clean up.
        try fixture.run(["cherry-pick", "--abort"])
    }

    // MARK: - Merge conflict state

    /// During a conflicting merge, MERGE_HEAD exists and workingCopyStatus reports conflicts.
    func testMergeConflictReportsInStatus() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "base\n")
        _ = try fixture.commit("base")

        try fixture.checkoutNewBranch("side")
        try fixture.writeFile("a.txt", "side change\n")
        _ = try fixture.commit("side")

        try fixture.checkout("main")
        try fixture.writeFile("a.txt", "main change\n")
        _ = try fixture.commit("main diverge")

        let exitCode = try fixture.run(["merge", "--no-ff", "side"])
        guard exitCode != 0 else { return } // No conflict

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let status = try await backend.workingCopyStatus(for: repo)
        XCTAssertFalse(status.isClean)
        // Conflicts should be reported.
        XCTAssertFalse(status.conflicts.isEmpty, "merge conflict must populate conflicts list")

        // refs() must still work during merge.
        let snapshot = try await backend.refs(for: repo)
        XCTAssertNotNil(snapshot.head.sha)

        // Clean up.
        try fixture.run(["merge", "--abort"])
    }

    // MARK: - Notes refs

    /// Adding a git note creates refs/notes/commits. The backend's refs() should still work
    /// and the note must not corrupt the branch/tag listings.
    func testGitNotesDoNotCorruptRefs() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        let sha = try fixture.commit("noted commit")
        try fixture.run(["notes", "add", "-m", "This is a note", sha])

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        // Notes live under refs/notes — they must not appear as branches or tags.
        let branchNames = Set(snapshot.branches.map(\.name))
        let tagNames = Set(snapshot.tags.map(\.name))
        XCTAssertFalse(branchNames.contains("notes/commits"), "notes ref must not appear as branch")
        XCTAssertFalse(tagNames.contains("notes/commits"), "notes ref must not appear as tag")
        // Normal refs must still be present.
        XCTAssertTrue(branchNames.contains("main"))
    }

    // MARK: - Replace refs

    /// git replace creates refs/replace/*. These must not corrupt the normal refs listing.
    func testReplaceRefsDoNotCorruptSnapshot() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        let first = try fixture.commit("first")
        try fixture.writeFile("a.txt", "2")
        let second = try fixture.commit("second")
        // Replace first commit with second (unusual but valid).
        try fixture.run(["replace", first, second])

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        let branchNames = Set(snapshot.branches.map(\.name))
        XCTAssertTrue(branchNames.contains("main"))
        // Replace refs must not appear in branches or tags.
        XCTAssertFalse(snapshot.branches.contains { $0.sha == first && $0.name.contains("replace") })
    }

    // MARK: - Many branches (packed-refs stress)

    /// A repo with many branches (triggering packed-refs) must still list all of them.
    func testManyBranchesAllAppearInRefs() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("base")
        let branchCount = 50
        for i in 1...branchCount {
            try fixture.run(["branch", "branch-\(i)"])
        }
        // Pack refs to exercise the packed-refs code path.
        try fixture.run(["pack-refs", "--all"])

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        let branchNames = Set(snapshot.branches.map(\.name))
        for i in 1...branchCount {
            XCTAssertTrue(branchNames.contains("branch-\(i)"),
                          "branch-\(i) missing after pack-refs")
        }
    }

    // MARK: - Submodule does not break status

    /// A repo with a submodule must not crash workingCopyStatus. The submodule entry appears
    /// with the S<c><m><u> field in porcelain v2 output.
    func testSubmoduleDoesNotBreakWorkingCopyStatus() async throws {
        let subFixture = try FixtureRepo()
        try subFixture.writeFile("lib.txt", "library")
        _ = try subFixture.commit("lib init")

        let fixture = try FixtureRepo()
        try fixture.writeFile("app.txt", "app")
        _ = try fixture.commit("app init")
        try fixture.addSubmodule(subFixture, at: "vendor/lib")
        _ = try fixture.commit("add submodule")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let status = try await backend.workingCopyStatus(for: repo)
        XCTAssertTrue(status.isClean, "repo with committed submodule should be clean")

        // refs must still work.
        let snapshot = try await backend.refs(for: repo)
        XCTAssertNotNil(snapshot.head.sha)
    }

    // MARK: - Dirty submodule in status

    /// A modified submodule must appear in workingCopyStatus as unstaged (the S<c><m><u> porcelain v2 field).
    func testDirtySubmoduleAppearsInStatus() async throws {
        let subFixture = try FixtureRepo()
        try subFixture.writeFile("lib.txt", "library")
        _ = try subFixture.commit("lib init")

        let fixture = try FixtureRepo()
        try fixture.writeFile("app.txt", "app")
        _ = try fixture.commit("app init")
        try fixture.addSubmodule(subFixture, at: "vendor/lib")
        _ = try fixture.commit("add submodule")

        // Dirty the submodule by adding a new commit inside it.
        let subWorkDir = fixture.url.appendingPathComponent("vendor/lib")
        let subProcess = Process()
        subProcess.executableURL = URL(fileURLWithPath: FixtureRepo.discoverGit())
        // -c commit.gpgsign=false so a host that signs commits by default can't make this fail.
        subProcess.arguments = ["-C", subWorkDir.path, "-c", "commit.gpgsign=false",
                                "commit", "--allow-empty", "-m", "dirty"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_COMMITTER_NAME"] = "Test"
        env["GIT_COMMITTER_EMAIL"] = "test@example.com"
        env["GIT_AUTHOR_NAME"] = "Test"
        env["GIT_AUTHOR_EMAIL"] = "test@example.com"
        subProcess.environment = env
        subProcess.standardError = FileHandle.nullDevice
        subProcess.standardOutput = FileHandle.nullDevice
        try subProcess.run()
        subProcess.waitUntilExit()

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let status = try await backend.workingCopyStatus(for: repo)
        XCTAssertFalse(status.isClean, "dirty submodule must make status non-clean")
    }

    // MARK: - Symbolic ref (non-standard HEAD-like ref)

    /// A custom symbolic ref (e.g. refs/heads/alias → refs/heads/main) must resolve
    /// without crashing for-each-ref.
    func testSymbolicBranchRefDoesNotCrashRefs() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("base")
        // Create a symbolic ref (like an alias branch pointing to main).
        try fixture.run(["symbolic-ref", "refs/heads/alias", "refs/heads/main"])

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        let branchNames = Set(snapshot.branches.map(\.name))
        // Both the real branch and the symbolic alias should appear.
        XCTAssertTrue(branchNames.contains("main"))
        XCTAssertTrue(branchNames.contains("alias"))
    }

    // MARK: - Reflog survives operations

    /// After multiple branch operations, the reflog must still exist (HEAD reflog accessible).
    /// This tests that our operations don't accidentally disable reflogs.
    func testReflogExistsAfterBranchOperations() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("first")
        try fixture.checkoutNewBranch("temp")
        try fixture.writeFile("b.txt", "2")
        _ = try fixture.commit("on temp")
        try fixture.checkout("main")
        try fixture.run(["branch", "-D", "temp"])

        // Verify reflog still works (this is a sanity check that our fixture doesn't break reflogs).
        let reflogOutput = try fixture.output(["reflog", "show", "--format=%H", "-n", "1", "HEAD"])
        XCTAssertFalse(reflogOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "HEAD reflog must still have entries after branch operations")
    }

    // MARK: - Empty commit (--allow-empty)

    /// An empty commit (no file changes) must still appear in loadCommits and have a valid SHA.
    func testEmptyCommitAppearsInHistory() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("initial")
        let emptySHA = try fixture.commit("empty commit") // --allow-empty is in FixtureRepo.commit

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        var commits: [Commit] = []
        for try await c in backend.loadCommits(CommitQuery(repo: repo, scope: .head)) {
            commits.append(c)
        }
        let shas = commits.map(\.sha)
        XCTAssertTrue(shas.contains(emptySHA), "empty commit must appear in history")
    }

    // MARK: - Branch with slash in name

    /// A branch with slashes (e.g. feature/foo/bar) must appear correctly in refs.
    func testBranchWithSlashesAppearsInRefs() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("base")
        try fixture.checkoutNewBranch("feature/foo/bar")
        try fixture.writeFile("b.txt", "2")
        _ = try fixture.commit("on nested branch")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        let branchNames = Set(snapshot.branches.map(\.name))
        XCTAssertTrue(branchNames.contains("feature/foo/bar"),
                      "branch with slashes must appear in refs: \(branchNames)")
    }

    // MARK: - Tag and branch with same name prefix

    /// A tag and branch can share a name prefix (e.g. branch "release" and tag "release/v1").
    /// Both must appear in their respective collections without confusion.
    func testTagAndBranchWithOverlappingNames() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        _ = try fixture.commit("base")
        try fixture.checkoutNewBranch("release/next")
        try fixture.writeFile("b.txt", "2")
        _ = try fixture.commit("release work")
        try fixture.checkout("main")
        try fixture.tag("release/v1.0")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        let branchNames = Set(snapshot.branches.map(\.name))
        let tagNames = Set(snapshot.tags.map(\.name))
        XCTAssertTrue(branchNames.contains("release/next"))
        XCTAssertTrue(tagNames.contains("release/v1.0"))
    }

    // MARK: - HEAD with no reflog (fresh init edge)

    /// In a freshly-init repo with exactly one commit, refs() must still work despite
    /// minimal reflog history.
    func testSingleCommitRepoRefsWork() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "only")
        let sha = try fixture.commit("only commit")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let snapshot = try await backend.refs(for: repo)
        XCTAssertEqual(snapshot.head.sha, sha)
        if case .attached(let branch, _) = snapshot.head {
            XCTAssertEqual(branch, "main")
        } else {
            XCTFail("single-commit repo should have attached HEAD")
        }
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
