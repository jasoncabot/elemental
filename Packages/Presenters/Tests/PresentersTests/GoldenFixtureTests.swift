import Foundation
import XCTest
import GitData
import TestSupport
@testable import Presenters

/// Pins what the commit header and note viewer show for every checked-in fixture. A failure here
/// means the UI would change; if that's intended, re-record (ELEMENTAL_RECORD_GOLDENS=1) and let the
/// golden diff document it in review. See docs/golden-fixtures.md.
@MainActor
final class GoldenFixtureTests: XCTestCase {
    /// Any SHA works; a fixed one keeps captions stable.
    private let sha = "0123456789abcdef0123456789abcdef01234567"

    /// What the app holds after `CLIGitBackend.note(for:ref:in:)`, which trims git's output.
    private func entry(_ f: NoteFixture) -> CommitDetailPresenter.NoteEntry {
        CommitDetailPresenter.NoteEntry(ref: f.ref, text: f.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Notes → note viewer

    func testNotePresentationsMatchGoldens() throws {
        let fixtures = try TextFixtures.notes()
        XCTAssertGreaterThanOrEqual(fixtures.count, 10, "note fixtures went missing")
        for f in fixtures {
            let p = NotePresentation(note: entry(f), commitSHA: sha)
            Golden.assertMatches(Snapshot.note(p), group: "Notes", name: f.name)
        }
    }

    func testEveryNoteGoldenHasAFixture() throws {
        let names = Set(try TextFixtures.notes().map(\.name))
        XCTAssertEqual(Golden.orphans(group: "Notes", expected: names), [])
    }

    /// The `ai--` fixtures are git-ai logs unless their name says they're broken; everything else
    /// must never be mistaken for one.
    func testGitAIDetectionFollowsFixtureNaming() throws {
        for f in try TextFixtures.notes() {
            let expectAI = f.name.hasPrefix("ai--") && !f.name.contains("malformed")
            XCTAssertEqual(entry(f).gitAI != nil, expectAI, f.name)
        }
    }

    // MARK: Commit messages → header chips

    func testHeaderChipsMatchGoldens() throws {
        let fixtures = try TextFixtures.commitMessages()
        XCTAssertGreaterThanOrEqual(fixtures.count, 5, "commit fixtures went missing")
        for f in fixtures {
            let chips = CommitHeaderPresentation.chips(for: commit(f.text), notes: [], aiAuthorship: nil)
            Golden.assertMatches(Snapshot.chips(chips), group: "Header", name: f.name)
        }
    }

    /// Notes and AI authorship together: a git-ai note replaces the authorship chip, human notes sit
    /// alongside it, and every note pill opens its own note.
    func testHeaderChipsWithNotesMatchGoldens() throws {
        let notes = Dictionary(uniqueKeysWithValues: try TextFixtures.notes().map { ($0.name, entry($0)) })
        let message = try XCTUnwrap(TextFixtures.commitMessages().first { $0.name == "conventional-breaking-scope" })
        let authorship = AIAuthorshipRecord(files: [
            .init(path: "a.swift", authors: [.init(name: "Claude Code", lineCount: 30),
                                             .init(name: "Ana", lineCount: 30),
                                             .init(name: "Cursor", lineCount: 5)]),
        ])
        let cases: [(String, [String], AIAuthorshipRecord?)] = [
            ("with-human-notes-and-authorship", ["commits--prose", "review--long-prose"], authorship),
            ("with-git-ai-note-replacing-authorship", ["commits--prose", "ai--v3-sessions"], authorship),
            ("with-authorship-only", [], authorship),
        ]
        for (name, noteNames, record) in cases {
            let entries = try noteNames.map { try XCTUnwrap(notes[$0], $0) }
            let chips = CommitHeaderPresentation.chips(for: commit(message.text), notes: entries, aiAuthorship: record)
            Golden.assertMatches(Snapshot.chips(chips), group: "Header", name: name)
        }
    }

    func testEveryHeaderGoldenHasACase() throws {
        var names = Set(try TextFixtures.commitMessages().map(\.name))
        names.formUnion(["with-human-notes-and-authorship", "with-git-ai-note-replacing-authorship",
                         "with-authorship-only"])
        XCTAssertEqual(Golden.orphans(group: "Header", expected: names), [])
    }

    /// A fixture message split the way `git log --format=%s%n%b` hands it to the app.
    private func commit(_ message: String) -> Commit {
        var lines = message.components(separatedBy: "\n")
        let subject = lines.isEmpty ? "" : lines.removeFirst()
        if lines.first == "" { lines.removeFirst() }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        let who = Signature(name: "Fixture Author", email: "fixture@example.com")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return Commit(sha: sha, parents: [], author: who, committer: who, authorDate: date,
                      commitDate: date, subject: subject, body: body, refNames: [])
    }
}
