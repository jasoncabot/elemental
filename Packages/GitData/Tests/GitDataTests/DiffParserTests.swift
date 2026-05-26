import XCTest
@testable import GitData

final class DiffParserTests: XCTestCase {
    func testParsesSimpleModification() {
        let patch = """
        diff --git a/a.txt b/a.txt
        index 1234567..89abcde 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,3 @@
         line1
        -line2
        +line2 changed
        +line3
        """
        let files = DiffParser.parse(patch)
        XCTAssertEqual(files.count, 1)
        let f = files[0]
        XCTAssertEqual(f.newPath, "a.txt")
        XCTAssertEqual(f.additions, 2)
        XCTAssertEqual(f.deletions, 1)
        XCTAssertEqual(f.hunks.first?.lines.count, 4)
    }

    func testParsesAddedAndDeletedFiles() {
        let patch = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,1 @@
        +hello
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -bye
        """
        let files = DiffParser.parse(patch)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].status, .added)
        XCTAssertEqual(files[1].status, .deleted)
    }

    func testParsesRename() {
        let patch = """
        diff --git a/old.txt b/new.txt
        similarity index 100%
        rename from old.txt
        rename to new.txt
        """
        let files = DiffParser.parse(patch)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .renamed)
        XCTAssertEqual(files[0].oldPath, "old.txt")
        XCTAssertEqual(files[0].newPath, "new.txt")
    }

    func testMalformedInputDoesNotCrash() {
        let garbage = ["", "@@ totally broken", "diff --git", "+++ ", "@@ -x,y +z @@\n+a",
                       "\u{0}\u{1}\u{2}random bytes", String(repeating: "@@", count: 1000)]
        for input in garbage {
            _ = DiffParser.parse(input) // must not crash
        }
    }
}
