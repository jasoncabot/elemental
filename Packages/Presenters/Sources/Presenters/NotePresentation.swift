import Foundation
import GitData

/// Everything the note pill and the note viewer show for one git note, as plain strings and
/// colour roles. The App renders it verbatim; golden tests pin it so the viewer only changes when a
/// change is intended (see docs/golden-fixtures.md).
public struct NotePresentation: Hashable, Sendable {
    public enum TextStyle: Hashable, Sendable {
        /// Human-written prose: body font, reading line height.
        case prose
        /// Machine-structured text (git-ai logs): monospaced, columns preserved.
        case monospaced
    }

    public var title: String
    /// `refs/notes/ai · 1a2b3c4`
    public var caption: String
    public var pillText: String
    public var pillTooltip: String
    public var rawText: String
    public var rawStyle: TextStyle
    /// A readable summary for git-ai authorship logs; nil for ordinary notes.
    public var summary: AuthorshipSummary?

    public init(note: CommitDetailPresenter.NoteEntry, commitSHA: String) {
        caption = "\(note.ref) · \(commitSHA.prefix(7))"
        rawText = note.text
        if let ai = note.gitAI {
            let summary = AuthorshipSummary(ai)
            title = "AI Authorship"
            // The sparkle means "an agent wrote lines here"; an all-human log doesn't get one.
            pillText = summary.agentNames.isEmpty
                ? "git-ai"
                : "✦ " + summary.agentNames.prefix(2).joined(separator: " · ")
            pillTooltip = "Show AI authorship (\(note.ref))"
            rawStyle = .monospaced
            self.summary = summary
        } else {
            title = "Note"
            pillText = note.name == "commits" ? "Note" : "Note · \(note.name)"
            pillTooltip = "Show note (\(note.ref))"
            rawStyle = Self.looksMachineWritten(note) ? .monospaced : .prose
            summary = nil
        }
    }
}

extension NotePresentation {
    /// JSON (git-appraise reviews, a git-ai log too broken to parse) keeps its structure in a
    /// monospaced face; anything else is prose.
    static func looksMachineWritten(_ note: CommitDetailPresenter.NoteEntry) -> Bool {
        if note.name == "ai" { return true }
        let first = note.text.first { !$0.isWhitespace }
        return first == "{" || first == "["
    }
}

/// A git-ai authorship log resolved into who wrote what: no session or trace hashes outside of
/// tooltips, every contributor named, every range written for humans (`1–10, 15`).
public struct AuthorshipSummary: Hashable, Sendable {
    public struct Share: Hashable, Sendable {
        public var fraction: Double
        public var swatch: Swatch
    }

    public struct Contributor: Hashable, Sendable {
        public var name: String
        public var swatch: Swatch
        public var lineCount: Int
        public var countText: String
        /// Secondary lines under the name: model and director, stats, custom attributes.
        public var details: [String]
        /// Identifiers (session, tool session, transcript URL) — hover-only.
        public var tooltip: String
    }

    public struct Attribution: Hashable, Sendable {
        public var name: String
        public var swatch: Swatch
        public var rangesText: String
        public var countText: String
    }

    public struct File: Hashable, Sendable {
        public var path: String
        public var countText: String
        public var attributions: [Attribution]
    }

    public var overview: String
    /// Proportional share of attributed lines, in `contributors` order; empty when nothing is attributed.
    public var shares: [Share]
    public var contributors: [Contributor]
    public var files: [File]
    public var footer: String
    public var footerTooltip: String?
    /// Distinct names of agents that wrote at least one line, most lines first — the header pill.
    public var agentNames: [String]

    public init(_ ai: GitAINote) {
        let lines = ai.lineCounts
        let total = lines.values.reduce(0, +)
        let swatches = Self.swatches(for: ai)

        overview = Self.overview(ai, lines: lines, total: total)

        // Most lines first (ties keep note order), so the list leads with who wrote the most.
        // Swatches were assigned in note order above, so colours don't shift with the sort.
        let ranked = ai.contributors.enumerated().sorted { a, b in
            let la = lines[a.element.id] ?? 0, lb = lines[b.element.id] ?? 0
            return la != lb ? la > lb : a.offset < b.offset
        }.map { $0.element }

        shares = total == 0 ? [] : ranked.compactMap { c -> Share? in
            guard let n = lines[c.id], n > 0 else { return nil }
            return Share(fraction: Double(n) / Double(total), swatch: swatches[c.id] ?? .unknown)
        }

        contributors = ranked.map { c in
            let n = lines[c.id] ?? 0
            return Contributor(name: c.displayName, swatch: swatches[c.id] ?? .unknown, lineCount: n,
                               countText: Self.linesText(n), details: Self.details(for: c),
                               tooltip: Self.tooltip(for: c))
        }

        files = ai.files.map { file in
            File(path: file.path, countText: Self.linesText(file.lineCount),
                 attributions: file.attributions.map { a in
                     Attribution(name: ai.contributor(id: a.contributorID)?.displayName ?? a.contributorID,
                                 swatch: swatches[a.contributorID] ?? .unknown,
                                 rangesText: Self.formatRanges(a.ranges),
                                 countText: Self.linesText(a.lineCount))
                 })
        }

        var footer = "Recorded by git-ai"
        if let v = ai.gitAIVersion, !v.isEmpty { footer += " \(v)" }
        self.footer = footer + " · " + ai.schemaVersion
        footerTooltip = ai.baseCommitSHA.map { "Base commit \($0)" }

        var names: [String] = []
        for c in ranked where c.kind == .agent && (lines[c.id] ?? 0) > 0 && !names.contains(c.displayName) {
            names.append(c.displayName)
        }
        agentNames = names
    }

    /// `[1...10, 15...15]` → `1–10, 15`.
    public static func formatRanges(_ ranges: [ClosedRange<Int>]) -> String {
        ranges.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }
            .joined(separator: ", ")
    }

    static func linesText(_ n: Int) -> String { "\(n) line\(n == 1 ? "" : "s")" }

    private static func overview(_ ai: GitAINote, lines: [String: Int], total: Int) -> String {
        guard total > 0 else { return "No lines in this commit are attributed to anyone." }
        let agents = ai.contributors.filter { $0.kind == .agent }
        let agentLines = agents.reduce(0) { $0 + (lines[$1.id] ?? 0) }
        var names: [String] = []
        for a in agents where (lines[a.id] ?? 0) > 0 && !names.contains(a.displayName) {
            names.append(a.displayName)
        }
        let who = names.count == 1 ? names[0] : "AI agents"
        let fileText = "\(ai.files.count) file\(ai.files.count == 1 ? "" : "s")"
        if agentLines == 0 { return "All \(total) attributed lines across \(fileText) were written by people." }
        if agentLines == total { return "\(who) wrote all \(total) attributed lines across \(fileText)." }
        return "\(who) wrote \(agentLines) of \(total) attributed lines across \(fileText)."
    }

    /// Agents and humans each count up from 0 in order of appearance; the view maps index → hue.
    private static func swatches(for ai: GitAINote) -> [String: Swatch] {
        var result: [String: Swatch] = [:]
        var agents = 0, humans = 0
        for c in ai.contributors {
            switch c.kind {
            case .agent:   result[c.id] = .agent(agents); agents += 1
            case .human:   result[c.id] = .human(humans); humans += 1
            case .unknown: result[c.id] = .unknown
            }
        }
        return result
    }

    private static func details(for c: GitAINote.Contributor) -> [String] {
        switch c.kind {
        case .agent:
            var details: [String] = []
            let identity = [c.displayModel, c.displayHuman.map { "directed by \($0)" }].compactMap { $0 }
            if !identity.isEmpty { details.append(identity.joined(separator: " · ")) }
            if let s = c.stats {
                details.append("+\(s.additions) −\(s.deletions) · \(s.acceptedLines) accepted"
                               + (s.overriddenLines > 0 ? " · \(s.overriddenLines) edited by a human" : ""))
            }
            if !c.customAttributes.isEmpty {
                details.append(c.customAttributes.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }.joined(separator: " · "))
            }
            return details
        case .human:
            // The name is already the row title; the detail is just how to reach them.
            guard let identity = c.human, !identity.isEmpty else { return [] }
            if let lt = identity.firstIndex(of: "<"), let gt = identity.lastIndex(of: ">"), lt < gt {
                let email = identity[identity.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces)
                return email.isEmpty ? [] : [email]
            }
            return identity == c.displayName ? [] : [identity]
        case .unknown:
            return ["Not described in the note's metadata"]
        }
    }

    private static func tooltip(for c: GitAINote.Contributor) -> String {
        var tip = [c.kind == .human ? "Human \(c.id)" : "Session \(c.id)"]
        if let sid = c.sessionID { tip.append("Tool session \(sid)") }
        if let url = c.messagesURL { tip.append("Transcript \(url)") }
        return tip.joined(separator: "\n")
    }
}
