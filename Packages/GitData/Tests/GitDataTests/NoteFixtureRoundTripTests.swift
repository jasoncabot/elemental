import XCTest
import TestSupport
@testable import GitData

/// Every note fixture survives a trip through real git: stored under its ref, discovered by
/// `noteRefs`, and read back by the backend as the app will see it. The presenters' golden tests
/// start from that same read-back text, so the two together pin "bytes in git" → "pixels' content".
final class NoteFixtureRoundTripTests: XCTestCase {

    func testEveryNoteFixtureRoundTripsThroughGit() async throws {
        let fixtures = try TextFixtures.notes()
        XCTAssertFalse(fixtures.isEmpty)

        let repo = try FixtureRepo()

        // One commit can carry one note per ref, so use a commit per fixture.
        var shas: [String: String] = [:]
        for (i, f) in fixtures.enumerated() {
            try repo.writeFile("a.txt", "\(i)")
            let commit = try repo.commit("note \(f.name)")
            // `-C <blob>` stores the bytes verbatim; `-m`/`-F` would run git's stripspace cleanup.
            let blob = try repo.output(["hash-object", "-w", "--no-filters", f.fixture.url.path])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(try repo.run(["notes", "--ref=\(f.ref)", "add", "-C", blob, commit]), 0, f.name)
            shas[f.name] = commit
        }

        let backend = try CLIGitBackend()
        let opened = try await backend.openRepository(at: repo.url)

        let refs = Set(try await backend.noteRefs(for: opened))
        XCTAssertEqual(refs, Set(fixtures.map(\.ref)))

        for f in fixtures {
            let read = try await backend.note(for: shas[f.name]!, ref: f.ref, in: opened)
            XCTAssertEqual(read, f.text.trimmingCharacters(in: .whitespacesAndNewlines), f.name)
        }
    }

    /// The parser must agree with the fixture naming: `ai--*` are git-ai logs unless malformed.
    func testParserClassifiesEveryNoteFixture() throws {
        for f in try TextFixtures.notes() {
            let expectAI = f.name.hasPrefix("ai--") && !f.name.contains("malformed")
            let parsed = GitAINoteParser.parse(f.text.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(parsed != nil, expectAI, f.name)
        }
    }

    func testLongEsotericFixtureResolvesEveryEdgeCase() throws {
        let f = try XCTUnwrap(TextFixtures.notes().first { $0.name == "ai--v3-long-esoteric" })
        let note = try XCTUnwrap(GitAINoteParser.parse(f.text))
        let paths = note.files.map(\.path)
        XCTAssertTrue(paths.contains("docs/design notes/AI \"authorship\" viewer.md"), "quoted path")
        XCTAssertTrue(paths.contains("tabs\tand\\backslashes.txt"), "escaped path")
        XCTAssertTrue(paths.contains("App/Résumé/Ünïcødé 名前.swift"), "unicode path")
        XCTAssertFalse(paths.contains("empty/attestation/only.txt"), "files with no lines are dropped")

        // Two trace IDs of one session in one file merge, sorted by start line.
        let parser = try XCTUnwrap(note.files.first { $0.path.hasSuffix("GitAINoteParser.swift") })
        let claude = try XCTUnwrap(parser.attributions.first { $0.contributorID == "s_aaaaaaaaaaaaaa" })
        XCTAssertEqual(claude.ranges, [1...40, 45...60, 120...180])

        XCTAssertEqual(note.contributor(id: "s_ffffffffffffff")?.kind, .unknown)
        XCTAssertEqual(note.contributor(id: "s_eeeeeeeeeeeeee")?.kind, .agent, "metadata-only session kept")
        XCTAssertNil(note.lineCounts["s_eeeeeeeeeeeeee"])
        XCTAssertEqual(note.contributor(id: "s_dddddddddddddd")?.displayName, "Aider")
        XCTAssertNil(note.contributor(id: "s_dddddddddddddd")?.displayModel, "empty model hidden")
        XCTAssertEqual(note.contributor(id: "0123456789abcdef")?.messagesURL,
                       "https://transcripts.example.invalid/c/77")
    }

    func testCRLFFixtureParsesLikeLF() throws {
        let f = try XCTUnwrap(TextFixtures.notes().first { $0.name == "ai--crlf-line-endings" })
        XCTAssertTrue(f.text.contains("\r\n"), "fixture lost its CRLF line endings")
        let note = try XCTUnwrap(GitAINoteParser.parse(f.text))
        XCTAssertEqual(note.files.map(\.path), ["src/windows.cs"])
        XCTAssertEqual(note.lineCounts["s_12121212121212"], 5)
    }
}
