import XCTest
import TestSupport
@testable import Presenters

/// git-ai keeps a tracking copy of each remote's notes at `refs/notes/ai-remote/<remote>` beside
/// its own `refs/notes/ai`, so a fetched repo holds the same log under two refs. The header must
/// show one pill for it, not one per ref.
final class NoteMirrorTests: XCTestCase {
    private typealias Entry = CommitDetailPresenter.NoteEntry

    private func gitAI() throws -> String {
        let f = try XCTUnwrap(TextFixtures.notes().first { $0.name == "ai--v3-sessions" })
        return f.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testIdenticalGitAILogInMirrorRefShowsOnce() throws {
        let text = try gitAI()
        let entries = [Entry(ref: "refs/notes/ai", text: text),
                       Entry(ref: "refs/notes/ai-remote/origin", text: text)]
        XCTAssertEqual(Entry.collapsingMirrors(entries).map(\.ref), ["refs/notes/ai"])
    }

    func testLocalRefWinsEvenWhenListedAfterItsMirror() throws {
        let text = try gitAI()
        let entries = [Entry(ref: "refs/notes/ai-remote/origin", text: text),
                       Entry(ref: "refs/notes/ai", text: text)]
        XCTAssertEqual(Entry.collapsingMirrors(entries).map(\.ref), ["refs/notes/ai"])
    }

    func testSeveralRemotesStillCollapseToOne() throws {
        let text = try gitAI()
        let entries = [Entry(ref: "refs/notes/ai", text: text),
                       Entry(ref: "refs/notes/ai-remote/origin", text: text),
                       Entry(ref: "refs/notes/ai-remote/upstream", text: text)]
        XCTAssertEqual(Entry.collapsingMirrors(entries).count, 1)
    }

    func testMirrorAloneIsKept() throws {
        let entries = [Entry(ref: "refs/notes/ai-remote/origin", text: try gitAI())]
        XCTAssertEqual(Entry.collapsingMirrors(entries).map(\.ref), ["refs/notes/ai-remote/origin"])
    }

    func testDifferentGitAILogsAreBothKept() throws {
        let legacy = try XCTUnwrap(TextFixtures.notes().first { $0.name == "ai--legacy-prompts" })
        let entries = [Entry(ref: "refs/notes/ai", text: try gitAI()),
                       Entry(ref: "refs/notes/ai-remote/origin", text: legacy.text)]
        XCTAssertEqual(Entry.collapsingMirrors(entries).count, 2)
    }

    func testHumanNotesWithTheSameTextAreNeverMerged() {
        let entries = [Entry(ref: "refs/notes/commits", text: "LGTM"),
                       Entry(ref: "refs/notes/review", text: "LGTM")]
        XCTAssertEqual(Entry.collapsingMirrors(entries).map(\.ref),
                       ["refs/notes/commits", "refs/notes/review"])
    }

    func testOrderOfOtherNotesIsPreserved() throws {
        let text = try gitAI()
        let entries = [Entry(ref: "refs/notes/ai", text: text),
                       Entry(ref: "refs/notes/ai-remote/origin", text: text),
                       Entry(ref: "refs/notes/commits", text: "hello")]
        XCTAssertEqual(Entry.collapsingMirrors(entries).map(\.ref), ["refs/notes/ai", "refs/notes/commits"])
    }
}
