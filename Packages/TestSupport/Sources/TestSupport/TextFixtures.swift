import Foundation

/// A checked-in text fixture: real-world-shaped input that tests across packages share, so the
/// data layer (does git round-trip it?) and the presenters (what does the UI show for it?) are
/// pinned against the same bytes. See docs/golden-fixtures.md.
public struct TextFixture {
    /// File name without extension, e.g. `ai--v3-long-esoteric`. Goldens are keyed by this.
    public let name: String
    /// Exact file contents — line endings and trailing whitespace preserved.
    public let text: String
    public let url: URL
}

/// A git note fixture. File names encode the notes ref: `<ref>--<case>.note`, where `<ref>` is the
/// part after `refs/notes/` with `~` standing in for `/` (`devtools~reviews--x.note` →
/// `refs/notes/devtools/reviews`).
public struct NoteFixture {
    public let fixture: TextFixture
    public let ref: String
    public var name: String { fixture.name }
    public var text: String { fixture.text }
}

public enum TextFixtures {
    /// Resolved from this source file so tests read (and goldens are written) in the checkout, not
    /// a build-products bundle.
    public static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    /// Every fixture in `Fixtures/<group>` with the given extension, sorted by name.
    public static func load(group: String, ext: String) throws -> [TextFixture] {
        let dir = root.appendingPathComponent(group, isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let data = try Data(contentsOf: url)
                return TextFixture(name: url.deletingPathExtension().lastPathComponent,
                                   text: String(decoding: data, as: UTF8.self), url: url)
            }
    }

    /// `Fixtures/Notes/*.note`.
    public static func notes() throws -> [NoteFixture] {
        try load(group: "Notes", ext: "note").map { f in
            let short = f.name.components(separatedBy: "--").first ?? f.name
            return NoteFixture(fixture: f,
                               ref: "refs/notes/" + short.replacingOccurrences(of: "~", with: "/"))
        }
    }

    /// `Fixtures/Commits/*.commit` — full commit messages (subject line, blank line, body).
    public static func commitMessages() throws -> [TextFixture] {
        try load(group: "Commits", ext: "commit")
    }
}
