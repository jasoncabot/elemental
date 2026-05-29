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

    func testDiffForRootCommitShowsFileAsAdded() async throws {
        // The initial commit has no parent. `diff-tree` emits nothing for it without --root, so
        // this pins that the backend passes --root and the root commit is shown as additions.
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "line1\nline2\n")
        let root = try fixture.commit("root")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let files = try await backend.diff(.commit(root), in: repo)
        let file = try XCTUnwrap(files.first { $0.displayPath == "a.txt" })
        XCTAssertEqual(file.status, .added)
        XCTAssertGreaterThan(file.additions, 0)
        XCTAssertEqual(file.deletions, 0)
    }

    func testDiffForMergeCommitShowsFirstParentChanges() async throws {
        // git show defaults to a combined (--cc) diff for merges, which is empty for a
        // conflict-free merge and unparseable. The backend uses -m --first-parent instead, so a
        // merge shows what it brought in relative to the first parent.
        let fixture = try FixtureRepo()
        try fixture.writeFile("base.txt", "base\n")
        _ = try fixture.commit("base")

        try fixture.checkoutNewBranch("feature")
        try fixture.writeFile("feat.txt", "feature\n")
        _ = try fixture.commit("feature work")

        try fixture.checkout("main")
        try fixture.merge("feature", message: "merge feature")
        let mergeSHA = try fixture.revParse("HEAD")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let files = try await backend.diff(.commit(mergeSHA), in: repo)
        XCTAssertTrue(files.contains { $0.displayPath == "feat.txt" },
                      "merge diff must show the file the merge introduced relative to first parent")
    }

    func testDiffUnstagedShowsWorkingTreeChanges() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "line1\n")
        _ = try fixture.commit("first")
        try fixture.writeFile("a.txt", "line1\nline2\n")   // modify, do not stage

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let files = try await backend.diff(.workingUnstaged, in: repo)
        let file = try XCTUnwrap(files.first { $0.displayPath == "a.txt" })
        XCTAssertGreaterThan(file.additions, 0)
    }

    func testDiffStagedShowsIndexChanges() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "line1\n")
        _ = try fixture.commit("first")
        try fixture.writeFile("a.txt", "line1\nstaged change\n")
        try fixture.run(["add", "a.txt"])                  // stage it

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let files = try await backend.diff(.workingStaged, in: repo)
        let file = try XCTUnwrap(files.first { $0.displayPath == "a.txt" })
        XCTAssertGreaterThan(file.additions, 0)
    }

    func testDiffStagedOnUnbornBranchShowsAdditions() async throws {
        // Files staged before the first commit have no HEAD to diff against; the backend falls
        // back to the empty tree so they appear as additions rather than throwing.
        let fixture = try FixtureRepo.makeEmpty()
        try fixture.writeFile("new.txt", "hello\nworld\n")
        try fixture.run(["add", "new.txt"])

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let files = try await backend.diff(.workingStaged, in: repo)
        let file = try XCTUnwrap(files.first { $0.displayPath == "new.txt" })
        XCTAssertEqual(file.status, .added)
        XCTAssertGreaterThan(file.additions, 0)
    }

    func testDiffUntrackedShowsFileAsAdditions() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("tracked.txt", "x\n")
        _ = try fixture.commit("first")
        try fixture.writeFile("brand-new.txt", "alpha\nbeta\n")   // untracked, never added

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let files = try await backend.diff(.workingUntracked("brand-new.txt"), in: repo)
        let file = try XCTUnwrap(files.first { $0.displayPath == "brand-new.txt" })
        XCTAssertEqual(file.status, .untracked)
        XCTAssertGreaterThan(file.additions, 0)
    }

    func testPreparedCommitMessageReadsMergeMsgButNotStaleCommit() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "x\n")
        _ = try fixture.commit("first commit")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)

        // After a plain commit there is no in-progress message (COMMIT_EDITMSG is ignored on
        // purpose, so the last commit's message must NOT leak through as a draft).
        let none = try await backend.preparedCommitMessage(for: repo)
        XCTAssertNil(none)

        // Simulate git mid-merge: MERGE_MSG holds the prepared message (with a comment line).
        let msgURL = repo.gitDir.appendingPathComponent("MERGE_MSG")
        try "Merge branch 'feature'\n\n# Please enter a commit message.\n"
            .write(to: msgURL, atomically: true, encoding: .utf8)
        let prepared = try await backend.preparedCommitMessage(for: repo)
        XCTAssertEqual(prepared, "Merge branch 'feature'")
    }

    func testDiffBetweenTwoCommits() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "v1\n")
        let first = try fixture.commit("first")
        try fixture.writeFile("a.txt", "v2\n")
        try fixture.writeFile("b.txt", "new\n")
        let second = try fixture.commit("second")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let files = try await backend.diff(.between(first, second), in: repo)
        XCTAssertTrue(files.contains { $0.displayPath == "a.txt" })
        XCTAssertTrue(files.contains { $0.displayPath == "b.txt" })
    }

    func testNoteForCommitReturnsNote() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        let sha = try fixture.commit("noted commit")
        try fixture.addNote("Reviewed — see issue #42", to: "HEAD")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let note = try await backend.note(for: sha, in: repo)
        XCTAssertEqual(note, "Reviewed — see issue #42")
    }

    func testNoteForCommitWithoutNoteIsNil() async throws {
        let fixture = try FixtureRepo()
        try fixture.writeFile("a.txt", "1")
        let sha = try fixture.commit("plain commit")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let note = try await backend.note(for: sha, in: repo)
        XCTAssertNil(note)
    }

    func testDiffSurfacesFunctionContext() async throws {
        // Git only repeats the enclosing function in the hunk header when the change is beyond the
        // surrounding context window, so the function body must be long enough to push it there.
        let fixture = try FixtureRepo()
        var lines = ["func computeTotal() {"]
        for i in 1...12 { lines.append("    let v\(i) = \(i)") }
        lines.append("    return 0")
        lines.append("}")
        let original = lines.joined(separator: "\n")
        try fixture.writeFile("calc.swift", original + "\n")
        _ = try fixture.commit("first")
        let edited = original.replacingOccurrences(of: "let v10 = 10", with: "let v10 = 1000")
        try fixture.writeFile("calc.swift", edited + "\n")
        let sha = try fixture.commit("tweak deep line")

        let backend = try makeBackend()
        let repo = try await backend.openRepository(at: fixture.url)
        let files = try await backend.diff(.commit(sha), in: repo)
        let hunk = try XCTUnwrap(files.first?.hunks.first)
        XCTAssertNotNil(hunk.context, "expected git to report the enclosing function as hunk context")
        XCTAssertTrue(hunk.context?.contains("func computeTotal") ?? false,
                      "context should name the enclosing function, got: \(hunk.context ?? "nil")")
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
