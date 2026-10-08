import Foundation

/// A git-ai authorship log attached to a commit as a git note (git-ai standard v3,
/// https://github.com/git-ai-project/git-ai). The raw note is written for machines — session and
/// trace hashes keyed to line ranges — so this resolves every key to the agent or human it names,
/// letting the UI say "Claude Code wrote lines 1–10 of main.rs" instead of `s_c9883b…::t_9f8e…`.
public struct GitAINote: Hashable, Sendable {
    /// Someone the log attributes lines to: an AI session (or legacy prompt) or a known human.
    public struct Contributor: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable { case agent, human, unknown }

        /// The attestation key with any `::t_…` trace suffix dropped (`s_…`, `h_…`, or legacy hash).
        public var id: String
        public var kind: Kind
        /// Agent tool as git-ai records it, e.g. `claude`, `cursor`, `codex`.
        public var tool: String?
        public var model: String?
        /// The tool's own session/conversation identifier.
        public var sessionID: String?
        /// For agents, the human who directed the session; for humans, their `Name <email>` identity.
        public var human: String?
        /// Legacy `prompts` entries carry per-session stats; v3 `sessions` do not.
        public var stats: Stats?
        public var messagesURL: String?
        public var customAttributes: [String: String]

        public struct Stats: Hashable, Sendable {
            public var additions: Int
            public var deletions: Int
            public var acceptedLines: Int
            public var overriddenLines: Int
        }

        public init(id: String, kind: Kind, tool: String? = nil, model: String? = nil,
                    sessionID: String? = nil, human: String? = nil, stats: Stats? = nil,
                    messagesURL: String? = nil, customAttributes: [String: String] = [:]) {
            self.id = id
            self.kind = kind
            self.tool = tool
            self.model = model
            self.sessionID = sessionID
            self.human = human
            self.stats = stats
            self.messagesURL = messagesURL
            self.customAttributes = customAttributes
        }
    }

    /// Lines in one file attributed to one contributor (trace IDs for the same session are merged).
    public struct Attribution: Hashable, Sendable {
        public var contributorID: String
        public var ranges: [ClosedRange<Int>]
        public var lineCount: Int { ranges.reduce(0) { $0 + $1.count } }
    }

    public struct File: Hashable, Sendable {
        public var path: String
        public var attributions: [Attribution]
        public var lineCount: Int { attributions.reduce(0) { $0 + $1.lineCount } }
    }

    public var schemaVersion: String
    public var gitAIVersion: String?
    public var baseCommitSHA: String?
    /// In order of first appearance in the attestation, then any metadata-only entries.
    public var contributors: [Contributor]
    public var files: [File]

    public func contributor(id: String) -> Contributor? { contributors.first { $0.id == id } }

    /// Attributed line count per contributor ID, across all files.
    public var lineCounts: [String: Int] {
        var totals: [String: Int] = [:]
        for file in files {
            for a in file.attributions { totals[a.contributorID, default: 0] += a.lineCount }
        }
        return totals
    }
}

public extension GitAINote.Contributor {
    /// A human-facing name: the agent's product name, or the human's name without their email.
    var displayName: String {
        switch kind {
        case .agent:   return Self.toolName(tool)
        case .human:   return Self.stripEmail(human ?? id)
        case .unknown: return "Unknown"
        }
    }

    /// The model without a trailing release-date stamp: `claude-sonnet-4-5-20250514` → `claude-sonnet-4-5`.
    var displayModel: String? {
        guard let model, !model.isEmpty else { return nil }
        let trimmed = model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        return trimmed.isEmpty ? model : trimmed
    }

    /// The directing human for an agent session, without their email.
    var displayHuman: String? {
        guard kind == .agent, let human, !human.isEmpty else { return nil }
        return Self.stripEmail(human)
    }

    private static func toolName(_ tool: String?) -> String {
        guard let tool, !tool.isEmpty else { return "AI agent" }
        switch tool.lowercased() {
        case "claude", "claude-code", "claude_code": return "Claude Code"
        case "cursor":                               return "Cursor"
        case "codex":                                return "Codex"
        case "github-copilot", "copilot":            return "GitHub Copilot"
        case "gemini", "gemini-cli":                 return "Gemini CLI"
        case "windsurf":                             return "Windsurf"
        case "opencode":                             return "OpenCode"
        default:
            return tool.prefix(1).uppercased() + tool.dropFirst()
        }
    }

    /// `Alice <alice@example.com>` → `Alice`; a bare email or name is returned as-is.
    private static func stripEmail(_ identity: String) -> String {
        let name = identity.replacingOccurrences(of: #"\s*<[^>]*>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? identity : name
    }
}

/// Parses a git-ai authorship note. Returns nil for any note that isn't one, so callers can try it
/// on every note and fall back to showing the text as-is.
///
/// Format: an attestation section, a line containing only `---`, then a JSON metadata object.
/// ```
/// src/main.rs
///   s_c9883b05a2487d::t_9f8e7d6c5b4a32 1-10,15-20
///   h_31dce776f88375 42-50
/// ---
/// { "schema_version": "authorship/3.0.0", "sessions": { "s_c9883b05a2487d": { "agent_id": {…} } }, … }
/// ```
public enum GitAINoteParser {

    public static func parse(_ text: String) -> GitAINote? {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let sep = lines.firstIndex(of: "---") else { return nil }

        let json = lines[(sep + 1)...].joined(separator: "\n")
        guard let data = json.data(using: .utf8),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = meta["schema_version"] as? String,
              schema.hasPrefix("authorship/") else { return nil }

        let sessions = meta["sessions"] as? [String: Any] ?? [:]
        let humans = meta["humans"] as? [String: Any] ?? [:]
        let prompts = meta["prompts"] as? [String: Any] ?? [:]

        // Attestation: unindented path lines, each followed by `  <key> <ranges>` entries.
        var files: [GitAINote.File] = []
        var seenIDs: [String] = []
        for line in lines[..<sep] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if line.hasPrefix("  ") {
                guard !files.isEmpty else { continue }
                let entry = line.dropFirst(2)
                guard let space = entry.firstIndex(of: " ") else { continue }
                let key = String(entry[..<space])
                let ranges = parseRanges(String(entry[entry.index(after: space)...]))
                guard !ranges.isEmpty else { continue }
                let id = key.components(separatedBy: "::").first ?? key
                if !seenIDs.contains(id) { seenIDs.append(id) }
                if let i = files[files.count - 1].attributions.firstIndex(where: { $0.contributorID == id }) {
                    files[files.count - 1].attributions[i].ranges.append(contentsOf: ranges)
                    files[files.count - 1].attributions[i].ranges.sort { $0.lowerBound < $1.lowerBound }
                } else {
                    files[files.count - 1].attributions.append(.init(contributorID: id, ranges: ranges))
                }
            } else {
                files.append(.init(path: unquote(line), attributions: []))
            }
        }
        files.removeAll { $0.attributions.isEmpty }

        // Metadata-only contributors (no surviving lines) still matter: they show who was involved.
        let metadataIDs = (Array(sessions.keys) + Array(humans.keys) + Array(prompts.keys)).sorted()
        for id in metadataIDs where !seenIDs.contains(id) { seenIDs.append(id) }

        let contributors = seenIDs.map { id in
            contributor(id: id, sessions: sessions, humans: humans, prompts: prompts)
        }

        return GitAINote(schemaVersion: schema,
                         gitAIVersion: meta["git_ai_version"] as? String,
                         baseCommitSHA: meta["base_commit_sha"] as? String,
                         contributors: contributors,
                         files: files)
    }

    private static func contributor(id: String, sessions: [String: Any], humans: [String: Any],
                                    prompts: [String: Any]) -> GitAINote.Contributor {
        if let human = humans[id] as? [String: Any] {
            return .init(id: id, kind: .human, human: human["author"] as? String)
        }
        if let entry = (sessions[id] ?? prompts[id]) as? [String: Any] {
            let agent = entry["agent_id"] as? [String: Any] ?? [:]
            var stats: GitAINote.Contributor.Stats?
            if let adds = entry["total_additions"] as? Int, let dels = entry["total_deletions"] as? Int {
                stats = .init(additions: adds, deletions: dels,
                              acceptedLines: entry["accepted_lines"] as? Int ?? 0,
                              overriddenLines: entry["overriden_lines"] as? Int ?? 0)
            }
            return .init(id: id, kind: .agent,
                         tool: agent["tool"] as? String,
                         model: agent["model"] as? String,
                         sessionID: agent["id"] as? String,
                         human: entry["human_author"] as? String,
                         stats: stats,
                         messagesURL: entry["messages_url"] as? String,
                         customAttributes: entry["custom_attributes"] as? [String: String] ?? [:])
        }
        return .init(id: id, kind: .unknown)
    }

    /// `1-10,15,20-22` → `[1...10, 15...15, 20...22]`. Malformed parts are skipped.
    static func parseRanges(_ text: String) -> [ClosedRange<Int>] {
        text.split(separator: ",").compactMap { part in
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            switch bounds.count {
            case 1:
                guard let n = bounds[0], n > 0 else { return nil }
                return n...n
            case 2:
                guard let lo = bounds[0], let hi = bounds[1], lo > 0, hi >= lo else { return nil }
                return lo...hi
            default:
                return nil
            }
        }
    }

    /// Paths containing whitespace are wrapped in double quotes with C-style escapes.
    private static func unquote(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        var result = ""
        var escaping = false
        for ch in path.dropFirst().dropLast() {
            if escaping {
                switch ch {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default:  result.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                result.append(ch)
            }
        }
        return result
    }
}
