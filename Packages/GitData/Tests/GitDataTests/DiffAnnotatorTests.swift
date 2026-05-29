import XCTest
@testable import GitData

/// Pure, git-free unit tests for the churn classifier. Patches are parsed by DiffParser, then
/// annotated, so these exercise the real pipeline the backend uses.
final class DiffAnnotatorTests: XCTestCase {

    private func annotate(_ patch: String) -> [DiffFile] {
        DiffAnnotator.annotate(DiffParser.parse(patch))
    }

    private func changedLines(_ files: [DiffFile]) -> [DiffLine] {
        files.flatMap { $0.hunks.flatMap(\.lines) }.filter { $0.kind != .context }
    }

    func testReindentIsWhitespace() {
        // Same content, different leading indentation → whitespace-only.
        let patch = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,1 +1,1 @@
        -  doSomething(withValue: 42)
        +    doSomething(withValue: 42)
        """
        for line in changedLines(annotate(patch)) {
            XCTAssertEqual(line.change, .whitespace, "reindented line should be whitespace: \(line.text)")
        }
    }

    func testTrailingWhitespaceIsWhitespace() {
        // Build with an explicit trailing space so it survives source formatting; the removed line
        // has it, the added line doesn't — a genuine whitespace-only change.
        let patch = [
            "diff --git a/a.swift b/a.swift",
            "--- a/a.swift",
            "+++ b/a.swift",
            "@@ -1,1 +1,1 @@",
            "-let value = compute() ",
            "+let value = compute()",
        ].joined(separator: "\n")
        for line in changedLines(annotate(patch)) {
            XCTAssertEqual(line.change, .whitespace)
        }
    }

    func testRealEditIsSubstantive() {
        // Differs by more than whitespace → substantive, not churn.
        let patch = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,1 +1,1 @@
        -let value = computeOldWay()
        +let value = computeNewWay()
        """
        for line in changedLines(annotate(patch)) {
            XCTAssertEqual(line.change, .substantive, "genuine edit must stay substantive: \(line.text)")
        }
    }

    func testMovedLineAcrossFilesIsMoved() {
        // The same significant line is removed from one file and added to another.
        let patch = """
        diff --git a/old.swift b/old.swift
        --- a/old.swift
        +++ b/old.swift
        @@ -1,2 +1,1 @@
         keep this line
        -let importantConfiguration = buildConfiguration()
        diff --git a/new.swift b/new.swift
        --- a/new.swift
        +++ b/new.swift
        @@ -1,1 +1,2 @@
         existing content
        +let importantConfiguration = buildConfiguration()
        """
        let moved = changedLines(annotate(patch))
        XCTAssertTrue(moved.allSatisfy { $0.change == .moved },
                      "relocated line should be moved on both sides: \(moved.map { ($0.text, $0.change) })")
    }

    func testMovedLineReindentedStillMoved() {
        // Moved and reindented: trimmed content matches, so still a move.
        let patch = """
        diff --git a/old.swift b/old.swift
        --- a/old.swift
        +++ b/old.swift
        @@ -1,1 +0,0 @@
        -registerHandler(forEvent: .didLaunch)
        diff --git a/new.swift b/new.swift
        --- a/new.swift
        +++ b/new.swift
        @@ -0,0 +1,1 @@
        +        registerHandler(forEvent: .didLaunch)
        """
        XCTAssertTrue(changedLines(annotate(patch)).allSatisfy { $0.change == .moved })
    }

    func testShortLinesNotTreatedAsMoved() {
        // A trivial line below the significance threshold must not be classed as a move.
        let patch = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,3 +1,3 @@
         context
        -}
         more
        diff --git a/b.swift b/b.swift
        --- a/b.swift
        +++ b/b.swift
        @@ -1,2 +1,3 @@
         alpha
        +}
         beta
        """
        XCTAssertTrue(changedLines(annotate(patch)).allSatisfy { $0.change == .substantive },
                      "short ubiquitous lines must not be matched as moves")
    }

    func testAddedAndDeletedFilesAreSubstantiveNotMoved() {
        // A genuine add and a genuine delete of *different* content stay substantive.
        let patch = """
        diff --git a/added.swift b/added.swift
        new file mode 100644
        --- /dev/null
        +++ b/added.swift
        @@ -0,0 +1,1 @@
        +let brandNewThing = createIt()
        diff --git a/gone.swift b/gone.swift
        deleted file mode 100644
        --- a/gone.swift
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -let unrelatedOldThing = destroyIt()
        """
        XCTAssertTrue(changedLines(annotate(patch)).allSatisfy { $0.change == .substantive })
    }

    func testContextLinesAlwaysSubstantive() {
        let patch = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,3 +1,3 @@
         unchanged context line here
        -let value = oldComputation()
        +let value = newComputation()
         another unchanged context line
        """
        let context = annotate(patch).flatMap { $0.hunks.flatMap(\.lines) }.filter { $0.kind == .context }
        XCTAssertFalse(context.isEmpty)
        XCTAssertTrue(context.allSatisfy { $0.change == .substantive })
    }
}
