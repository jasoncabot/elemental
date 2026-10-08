import Foundation
import GitData

/// A colour role. The view maps roles to system colours, so the palette lives in one place in the
/// App target while everything that decides *which* role a chip or contributor gets stays here,
/// AppKit-free and covered by golden tests.
public enum Swatch: Hashable, Sendable {
    /// A Conventional Commits type (`feat`, `fix`, …).
    case commitType(String)
    /// Scope, trailers — metadata that shouldn't draw the eye.
    case neutral
    /// A breaking-change flag.
    case danger
    case issue
    /// AI authorship.
    case ai
    /// A human-written git note.
    case note
    /// The nth AI agent in a git-ai note (stable within one note).
    case agent(Int)
    /// The nth human in a git-ai note.
    case human(Int)
    case unknown
}

/// One pill in the commit header's chip row.
public struct HeaderChip: Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        case none
        /// Open the note at this index of the header's notes.
        case openNote(Int)
    }

    public var text: String
    public var swatch: Swatch
    public var filled: Bool
    public var tooltip: String?
    public var action: Action

    public init(text: String, swatch: Swatch, filled: Bool, tooltip: String? = nil, action: Action = .none) {
        self.text = text
        self.swatch = swatch
        self.filled = filled
        self.tooltip = tooltip
        self.action = action
    }
}

/// Decides what the commit header's chip row shows. Pure: the same commit, notes and authorship
/// always give the same chips, which is what lets golden tests pin the header across releases.
public enum CommitHeaderPresentation {

    public static func chips(for commit: Commit,
                             notes: [CommitDetailPresenter.NoteEntry],
                             aiAuthorship: AIAuthorshipRecord?) -> [HeaderChip] {
        var chips: [HeaderChip] = []

        // Conventional commit type + scope + breaking flag.
        if let conv = commit.conventional {
            chips.append(HeaderChip(text: conv.type, swatch: .commitType(conv.type), filled: true))
            if let scope = conv.scope, !scope.isEmpty {
                chips.append(HeaderChip(text: scope, swatch: .neutral, filled: false))
            }
            if conv.isBreaking {
                chips.append(HeaderChip(text: "breaking", swatch: .danger, filled: false))
            }
        }

        // Key trailers: reviewers, co-authors, issue links.
        for trailer in commit.trailers where isDisplayTrailer(trailer.key) {
            chips.append(HeaderChip(text: trailerChipText(trailer), swatch: .neutral, filled: false))
        }

        // Issue refs not already expressed by a trailer chip (avoids showing #123 twice when
        // "Fixes: #123" is already shown as a trailer).
        let trailerValues = commit.trailers.map(\.value)
        for ref in commit.issueRefs where !trailerValues.contains(where: { $0.contains(ref.raw) }) {
            chips.append(HeaderChip(text: ref.raw, swatch: .issue, filled: false))
        }

        // Notes: one clickable pill each. A git-ai log reads as "✦ Claude Code", anything else as
        // "Note"; either opens the full note in the viewer.
        for (index, entry) in notes.enumerated() {
            let p = NotePresentation(note: entry, commitSHA: commit.sha)
            chips.append(HeaderChip(text: p.pillText,
                                    swatch: entry.gitAI != nil ? .ai : .note,
                                    filled: entry.gitAI == nil,
                                    tooltip: p.pillTooltip,
                                    action: .openNote(index)))
        }

        // AI authorship from `refs/ai/authorship/<sha>`: which agents contributed lines. Skipped
        // when a git-ai note already says the same thing as a clickable pill.
        if let aiAuthorship, !notes.contains(where: { $0.gitAI != nil }) {
            let agents = aiAuthorship.authorTotals
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(2).map(\.key)
            if !agents.isEmpty {
                chips.append(HeaderChip(text: "✦ " + agents.joined(separator: " · "),
                                        swatch: .ai, filled: false))
            }
        }

        return chips
    }

    static func isDisplayTrailer(_ key: String) -> Bool {
        switch key.lowercased() {
        case "reviewed-by", "co-authored-by", "co-author",
             "fixes", "closes", "resolves", "refs": return true
        default: return false
        }
    }

    /// `Co-authored-by: Alice <alice@example.com>` → `Co-authored-by: Alice`.
    static func trailerChipText(_ trailer: CommitTrailer) -> String {
        let value = trailer.value
            .replacingOccurrences(of: #"\s*<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "\(trailer.key): \(value)"
    }
}
