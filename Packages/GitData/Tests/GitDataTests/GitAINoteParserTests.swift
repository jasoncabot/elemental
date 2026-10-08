import XCTest
@testable import GitData

final class GitAINoteParserTests: XCTestCase {

    /// The sessions-format example from the git-ai standard v3 spec.
    private let v3Note = """
    src/main.rs
      s_c9883b05a2487d::t_9f8e7d6c5b4a32 1-10,15-20
      s_c9883b05a2487d::t_a1b2c3d4e5f678 25,30-35
      h_31dce776f88375 42-50
    src/lib.rs
      s_e7f2a90b31cc48::t_deadbeef012345 1-50
    ---
    {
      "schema_version": "authorship/3.0.0",
      "git_ai_version": "1.4.5",
      "base_commit_sha": "7734793b756b3921c88db5375a8c156e9532447b",
      "prompts": {},
      "humans": {
        "h_31dce776f88375": { "author": "Developer <dev@example.com>" }
      },
      "sessions": {
        "s_c9883b05a2487d": {
          "agent_id": { "tool": "cursor", "id": "6ef2299e", "model": "claude-sonnet-4-5-20250514" },
          "human_author": "dev@example.com"
        },
        "s_e7f2a90b31cc48": {
          "agent_id": { "tool": "claude", "id": "conv_abc123", "model": "claude-sonnet-4-5-20250514" },
          "human_author": "Developer <dev@example.com>",
          "custom_attributes": { "team": "backend" }
        }
      }
    }
    """

    func testParsesV3SessionsNote() throws {
        let note = try XCTUnwrap(GitAINoteParser.parse(v3Note))
        XCTAssertEqual(note.schemaVersion, "authorship/3.0.0")
        XCTAssertEqual(note.gitAIVersion, "1.4.5")
        XCTAssertEqual(note.files.map(\.path), ["src/main.rs", "src/lib.rs"])
        XCTAssertEqual(note.contributors.map(\.id),
                       ["s_c9883b05a2487d", "h_31dce776f88375", "s_e7f2a90b31cc48"])
    }

    func testMergesTraceIDsOfTheSameSessionWithinAFile() throws {
        let note = try XCTUnwrap(GitAINoteParser.parse(v3Note))
        let main = note.files[0]
        XCTAssertEqual(main.attributions.count, 2)
        XCTAssertEqual(main.attributions[0].contributorID, "s_c9883b05a2487d")
        XCTAssertEqual(main.attributions[0].ranges, [1...10, 15...20, 25...25, 30...35])
        XCTAssertEqual(main.attributions[0].lineCount, 23)
        XCTAssertEqual(main.attributions[1].lineCount, 9)
    }

    func testLineCountsPerContributor() throws {
        let note = try XCTUnwrap(GitAINoteParser.parse(v3Note))
        XCTAssertEqual(note.lineCounts["s_c9883b05a2487d"], 23)
        XCTAssertEqual(note.lineCounts["h_31dce776f88375"], 9)
        XCTAssertEqual(note.lineCounts["s_e7f2a90b31cc48"], 50)
    }

    func testResolvesContributorsToReadableNames() throws {
        let note = try XCTUnwrap(GitAINoteParser.parse(v3Note))
        let cursor = try XCTUnwrap(note.contributor(id: "s_c9883b05a2487d"))
        XCTAssertEqual(cursor.kind, .agent)
        XCTAssertEqual(cursor.displayName, "Cursor")
        XCTAssertEqual(cursor.displayModel, "claude-sonnet-4-5")
        XCTAssertEqual(cursor.displayHuman, "dev@example.com")

        let claude = try XCTUnwrap(note.contributor(id: "s_e7f2a90b31cc48"))
        XCTAssertEqual(claude.displayName, "Claude Code")
        XCTAssertEqual(claude.displayHuman, "Developer")
        XCTAssertEqual(claude.customAttributes, ["team": "backend"])

        let human = try XCTUnwrap(note.contributor(id: "h_31dce776f88375"))
        XCTAssertEqual(human.kind, .human)
        XCTAssertEqual(human.displayName, "Developer")
        XCTAssertNil(human.displayHuman)
    }

    func testParsesLegacyPromptsWithStats() throws {
        let text = """
        app.py
          0123456789abcdef 3-4
        ---
        {"schema_version":"authorship/3.0.0","base_commit_sha":"abc","prompts":{
          "0123456789abcdef":{"agent_id":{"tool":"codex","id":"x","model":"gpt-5"},
          "total_additions":12,"total_deletions":3,"accepted_lines":10,"overriden_lines":2}}}
        """
        let note = try XCTUnwrap(GitAINoteParser.parse(text))
        let c = try XCTUnwrap(note.contributor(id: "0123456789abcdef"))
        XCTAssertEqual(c.displayName, "Codex")
        XCTAssertEqual(c.stats, GitAINote.Contributor.Stats(additions: 12, deletions: 3, acceptedLines: 10, overriddenLines: 2))
    }

    func testUnknownKeysAndMetadataOnlySessionsAreKept() throws {
        let text = """
        a.txt
          s_00000000000000::t_11111111111111 1
        ---
        {"schema_version":"authorship/3.0.0","base_commit_sha":"abc","prompts":{},
         "sessions":{"s_22222222222222":{"agent_id":{"tool":"claude","id":"y","model":"m"}}}}
        """
        let note = try XCTUnwrap(GitAINoteParser.parse(text))
        XCTAssertEqual(note.contributors.map(\.kind), [.unknown, .agent])
        XCTAssertNil(note.lineCounts["s_22222222222222"])
    }

    func testUnquotesPathsWithSpaces() throws {
        let text = """
        "docs/read me.md"
          h_31dce776f88375 1-2
        ---
        {"schema_version":"authorship/3.0.0","base_commit_sha":"abc","prompts":{}}
        """
        let note = try XCTUnwrap(GitAINoteParser.parse(text))
        XCTAssertEqual(note.files.first?.path, "docs/read me.md")
    }

    func testRejectsNotesThatAreNotGitAI() {
        XCTAssertNil(GitAINoteParser.parse("Reviewed in standup — ship it."))
        XCTAssertNil(GitAINoteParser.parse("intro\n---\nnot json"))
        XCTAssertNil(GitAINoteParser.parse("x\n---\n{\"schema_version\":\"other/1.0\"}"))
    }

    func testDisplayModelDropsDateStamps() {
        func model(_ m: String) -> String? {
            GitAINote.Contributor(id: "s", kind: .agent, model: m).displayModel
        }
        XCTAssertEqual(model("claude-sonnet-4-5-20250514"), "claude-sonnet-4-5")
        XCTAssertEqual(model("gpt-4o-2024-08-06"), "gpt-4o")
        XCTAssertEqual(model("o3"), "o3")
        XCTAssertNil(model(""))
    }

    func testParseRangesSkipsMalformedParts() {
        XCTAssertEqual(GitAINoteParser.parseRanges("1-3,5,x,9-7,0,12-12"), [1...3, 5...5, 12...12])
    }
}
