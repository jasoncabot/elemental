import XCTest
@testable import GitData

final class TrailerParserTests: XCTestCase {

    func testParsesSimpleTrailers() {
        let body = """
        Longer description of the change.

        Reviewed-by: Alice <alice@example.com>
        Co-authored-by: Bob <bob@example.com>
        """
        let trailers = TrailerParser.parse(body)
        XCTAssertEqual(trailers.count, 2)
        XCTAssertEqual(trailers[0], CommitTrailer(key: "Reviewed-by", value: "Alice <alice@example.com>"))
        XCTAssertEqual(trailers[1], CommitTrailer(key: "Co-authored-by", value: "Bob <bob@example.com>"))
    }

    func testParsesFixesTrailer() {
        let body = """
        Fix the login bug.

        Fixes: #456
        Closes: #789
        """
        let trailers = TrailerParser.parse(body)
        XCTAssertEqual(trailers.count, 2)
        XCTAssertEqual(trailers[0].key, "Fixes")
        XCTAssertEqual(trailers[0].value, "#456")
        XCTAssertEqual(trailers[1].key, "Closes")
        XCTAssertEqual(trailers[1].value, "#789")
    }

    func testEmptyBodyProducesNoTrailers() {
        XCTAssertEqual(TrailerParser.parse("").count, 0)
        XCTAssertEqual(TrailerParser.parse("   \n  ").count, 0)
    }

    func testBodyWithNoTrailerBlockProducesNoTrailers() {
        let body = "This is a plain one-liner with no trailers."
        XCTAssertEqual(TrailerParser.parse(body).count, 0)
    }

    func testBodyWhereLastParagraphHasMixedLinesProducesNoTrailers() {
        let body = """
        Normal paragraph.

        This paragraph has some prose and then a trailer line, but the
        mixing means the whole block is not a valid trailer block.
        Fixes: #123
        """
        XCTAssertEqual(TrailerParser.parse(body).count, 0)
    }

    func testBodyWithoutTrailersStripsBlock() {
        let body = """
        This is the prose body.

        Second prose paragraph.

        Reviewed-by: Alice <alice@example.com>
        Co-authored-by: Bob <bob@example.com>
        """
        let stripped = TrailerParser.bodyWithoutTrailers(body)
        XCTAssertEqual(stripped, "This is the prose body.\n\nSecond prose paragraph.")
    }

    func testBodyWithoutTrailersLeavesPlainBodyUntouched() {
        let body = "Just a plain body with no trailers."
        XCTAssertEqual(TrailerParser.bodyWithoutTrailers(body), body)
    }

    func testBodyWithoutTrailersReturnsEmptyWhenBodyIsOnlyTrailers() {
        let body = "Reviewed-by: Alice <alice@example.com>"
        // Single paragraph, all trailers — body without trailers is empty.
        let stripped = TrailerParser.bodyWithoutTrailers(body)
        XCTAssertEqual(stripped, "")
    }

    func testDashInKey() {
        let body = """
        Some change.

        Signed-off-by: Charlie <charlie@example.com>
        """
        let trailers = TrailerParser.parse(body)
        XCTAssertEqual(trailers.count, 1)
        XCTAssertEqual(trailers[0].key, "Signed-off-by")
    }
}

final class ConventionalCommitParserTests: XCTestCase {

    func testParsesFeatWithScope() {
        let result = ConventionalCommitParser.parse("feat(auth): add OAuth2 login")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, "feat")
        XCTAssertEqual(result?.scope, "auth")
        XCTAssertFalse(result?.isBreaking ?? true)
        XCTAssertEqual(result?.description, "add OAuth2 login")
    }

    func testParsesFeatWithoutScope() {
        let result = ConventionalCommitParser.parse("fix: handle nil user gracefully")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, "fix")
        XCTAssertNil(result?.scope)
        XCTAssertFalse(result?.isBreaking ?? true)
    }

    func testParsesBreakingChange() {
        let result = ConventionalCommitParser.parse("feat(api)!: redesign REST endpoints")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, "feat")
        XCTAssertEqual(result?.scope, "api")
        XCTAssertTrue(result?.isBreaking ?? false)
    }

    func testParsesBreakingWithoutScope() {
        let result = ConventionalCommitParser.parse("refactor!: rename all public types")
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.isBreaking ?? false)
        XCTAssertNil(result?.scope)
    }

    func testReturnsNilForPlainSubject() {
        XCTAssertNil(ConventionalCommitParser.parse("Fix login bug"))
        XCTAssertNil(ConventionalCommitParser.parse("WIP"))
        XCTAssertNil(ConventionalCommitParser.parse(""))
    }

    func testReturnsNilForMissingSpace() {
        // Colon must be followed by a space.
        XCTAssertNil(ConventionalCommitParser.parse("feat:no space after colon"))
    }

    func testEmptyScopeIsNormalisedToNil() {
        let result = ConventionalCommitParser.parse("chore(): update deps")
        XCTAssertEqual(result?.type, "chore")
        XCTAssertNil(result?.scope)
    }

    func testChoreAndDocsTypes() {
        XCTAssertEqual(ConventionalCommitParser.parse("chore: tidy imports")?.type, "chore")
        XCTAssertEqual(ConventionalCommitParser.parse("docs(readme): add install instructions")?.type, "docs")
    }
}

final class IssueRefParserTests: XCTestCase {

    func testDetectsNumericRef() {
        let refs = IssueRefParser.parse(subject: "Fix crash (#123)", body: "")
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].raw, "#123")
        if case .numeric(let n) = refs[0].style { XCTAssertEqual(n, 123) }
        else { XCTFail("Expected .numeric style") }
    }

    func testDetectsPrefixedRef() {
        let refs = IssueRefParser.parse(subject: "Resolves JIRA-456", body: "")
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].raw, "JIRA-456")
        if case .prefixed(let s) = refs[0].style { XCTAssertEqual(s, "JIRA-456") }
        else { XCTFail("Expected .prefixed style") }
    }

    func testDeduplicatesAcrossSubjectAndBody() {
        let refs = IssueRefParser.parse(subject: "Fix #99", body: "See also #99 for context.")
        XCTAssertEqual(refs.count, 1)
    }

    func testDetectsMultipleRefs() {
        let refs = IssueRefParser.parse(subject: "Fix #1 and #2", body: "LINEAR-100 tracked this")
        XCTAssertEqual(refs.count, 3)
    }

    func testEmptyInputProducesNoRefs() {
        XCTAssertEqual(IssueRefParser.parse(subject: "", body: "").count, 0)
    }

    func testDoesNotMatchVersionNumbers() {
        // "v1.2" or "1.2.3" should not produce refs. "#" must precede the number.
        let refs = IssueRefParser.parse(subject: "Bump version to 1.2.3", body: "")
        XCTAssertEqual(refs.count, 0)
    }

    func testPrefixMustBeAtLeastTwoUppercaseLetters() {
        // Single-letter prefix like "A-1" should not match.
        let refs = IssueRefParser.parse(subject: "A-1 edge case", body: "")
        XCTAssertEqual(refs.count, 0)
    }
}
