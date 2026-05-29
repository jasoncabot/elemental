import Foundation

/// Control characters used to delimit `git log --format` output unambiguously.
enum LogFormat {
    static let unit = "\u{1f}"      // between fields
    static let record = "\u{1e}"    // between commits
    // Order must match parsing below.
    static let pretty = [
        "%H", "%P", "%an", "%ae", "%aI", "%cn", "%ce", "%cI", "%s", "%b", "%D"
    ].joined(separator: unit) + record
}

/// Builds the commit-walk invocation. `git log` is porcelain; `git rev-list` is its plumbing
/// equivalent, and is what we use so output never depends on `log.*` config, aliases, or pager.
///
/// `rev-list --format` prints a `commit <sha>` header line before each record. We deliberately
/// do *not* pass `--no-commit-header` (git ≥ 2.33 only) — instead `CommitParser` strips that
/// header, so every git version is supported with identical parsing.
enum CommitLog {
    static func revListArgs(for query: CommitQuery) -> [String] {
        // `rev-list` requires an explicit starting point — unlike `git log`, it has no implicit HEAD.
        var args = ["rev-list", "--parents", "--format=\(LogFormat.pretty)"]
        switch query.scope {
        case .head:          args.append("HEAD")
        case .branch(let b): args.append(b)
        case .ref(let r):    args.append(r)
        case .all:           args.append("--all")
        }
        if let maxCount = query.maxCount { args.append("--max-count=\(maxCount)") }
        if let skip = query.skip { args.append("--skip=\(skip)") }
        if let since = query.since {
            args.append("--since=\(ISO8601DateFormatter.gitISO.string(from: since))")
        }
        return args
    }
}

enum CommitParser {
    static func parse(_ data: Data, calendar: ISO8601DateFormatter = .gitISO) -> [Commit] {
        let text = String(decoding: data, as: UTF8.self)
        var commits: [Commit] = []
        for record in text.components(separatedBy: LogFormat.record) {
            var trimmed = record.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            if trimmed.isEmpty { continue }
            // `git rev-list --format` prefixes each record with a `commit <sha>` line. Drop it so
            // field[0] is the `%H` we asked for. A no-op when the header is absent (%H is hex).
            if trimmed.hasPrefix("commit "), let newline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: newline)...])
            }
            let fields = trimmed.components(separatedBy: LogFormat.unit)
            guard fields.count >= 11 else { continue }
            let parents = fields[1].split(separator: " ").map(String.init)
            let refNames = fields[10]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            commits.append(Commit(
                sha: fields[0],
                parents: parents,
                author: Signature(name: fields[2], email: fields[3]),
                committer: Signature(name: fields[5], email: fields[6]),
                authorDate: calendar.date(from: fields[4]) ?? .distantPast,
                commitDate: calendar.date(from: fields[7]) ?? .distantPast,
                subject: fields[8],
                body: fields[9],
                refNames: refNames
            ))
        }
        return commits
    }
}

enum RefParser {
    /// Parses `for-each-ref` output where each ref is: name\u{1f}objectname\u{1f}upstream\u{1f}ahead-behind\u{1e}
    static let format = ["%(refname)", "%(objectname)", "%(upstream:short)",
                         "%(upstream:track,nobracket)"].joined(separator: LogFormat.unit) + LogFormat.record

    static func parse(_ data: Data) -> [Ref] {
        let text = String(decoding: data, as: UTF8.self)
        var refs: [Ref] = []
        for record in text.components(separatedBy: LogFormat.record) {
            let trimmed = record.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            if trimmed.isEmpty { continue }
            let f = trimmed.components(separatedBy: LogFormat.unit)
            guard f.count >= 2 else { continue }
            let fullName = f[0]
            let sha = f[1]
            let upstream = f.count > 2 && !f[2].isEmpty ? f[2] : nil
            var ahead: Int?
            var behind: Int?
            if f.count > 3 {
                for token in f[3].split(separator: " ") {
                    if token.hasPrefix("ahead") { ahead = Int(token.dropFirst("ahead ".count)) ?? Int(token.split(separator: " ").last ?? "") }
                    if token.hasPrefix("behind") { behind = Int(token.dropFirst("behind ".count)) ?? Int(token.split(separator: " ").last ?? "") }
                }
                // track format like "ahead 2, behind 1"
                let parts = f[3].replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
                var i = 0
                while i < parts.count - 1 {
                    if parts[i] == "ahead" { ahead = Int(parts[i+1]) }
                    if parts[i] == "behind" { behind = Int(parts[i+1]) }
                    i += 1
                }
            }
            let (name, kind) = classify(fullName)
            refs.append(Ref(name: name, sha: sha, kind: kind, upstream: upstream, ahead: ahead, behind: behind))
        }
        return refs
    }

    private static func classify(_ fullName: String) -> (String, RefKind) {
        if fullName.hasPrefix("refs/heads/") {
            return (String(fullName.dropFirst("refs/heads/".count)), .branch)
        } else if fullName.hasPrefix("refs/remotes/") {
            return (String(fullName.dropFirst("refs/remotes/".count)), .remote)
        } else if fullName.hasPrefix("refs/tags/") {
            return (String(fullName.dropFirst("refs/tags/".count)), .tag)
        }
        return (fullName, .branch)
    }
}

enum StatusParser {
    /// Parses `git status --porcelain=v2 -z --branch` output.
    static func parse(_ data: Data) -> WorkingCopyStatus {
        let text = String(decoding: data, as: UTF8.self)
        let entries = text.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
        var branch: String?
        var ahead: Int?
        var behind: Int?
        var staged: [FileStatus] = []
        var unstaged: [FileStatus] = []
        var untracked: [FileStatus] = []
        var conflicts: [FileStatus] = []

        var index = 0
        while index < entries.count {
            let entry = entries[index]
            if entry.hasPrefix("# branch.head ") {
                branch = String(entry.dropFirst("# branch.head ".count))
            } else if entry.hasPrefix("# branch.ab ") {
                let parts = entry.dropFirst("# branch.ab ".count).split(separator: " ")
                for p in parts {
                    if p.hasPrefix("+") { ahead = Int(p.dropFirst()) }
                    if p.hasPrefix("-") { behind = Int(p.dropFirst()) }
                }
            } else if entry.hasPrefix("1 ") {
                // ordinary: 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                let (xy, path) = ordinaryFields(entry)
                if let s = xy.first, s != "." { staged.append(FileStatus(path: path, status: mapCode(s))) }
                if xy.count > 1, xy[xy.index(after: xy.startIndex)] != "." {
                    unstaged.append(FileStatus(path: path, status: mapCode(xy[xy.index(after: xy.startIndex)])))
                }
            } else if entry.hasPrefix("2 ") {
                // renamed/copied: like ordinary but a following NUL field holds the origin path
                let (xy, path) = ordinaryFields(entry)
                var origin: String?
                if index + 1 < entries.count {
                    origin = entries[index + 1]
                    index += 1
                }
                if let s = xy.first, s != "." {
                    staged.append(FileStatus(path: path, originalPath: origin, status: mapCode(s)))
                }
                if xy.count > 1, xy[xy.index(after: xy.startIndex)] != "." {
                    unstaged.append(FileStatus(path: path, originalPath: origin, status: mapCode(xy[xy.index(after: xy.startIndex)])))
                }
            } else if entry.hasPrefix("u ") {
                let path = String(entry.split(separator: " ").last ?? "")
                conflicts.append(FileStatus(path: path, status: .unmerged))
            } else if entry.hasPrefix("? ") {
                untracked.append(FileStatus(path: String(entry.dropFirst(2)), status: .untracked))
            } else if entry.hasPrefix("! ") {
                // ignored — skipped by default
            }
            index += 1
        }
        return WorkingCopyStatus(branch: branch, ahead: ahead, behind: behind,
                                 staged: staged, unstaged: unstaged,
                                 untracked: untracked, conflicts: conflicts)
    }

    private static func ordinaryFields(_ entry: String) -> (xy: String, path: String) {
        // Drop the leading "1 " / "2 ", split off 8 metadata fields, the rest is the path.
        // After the leading code: "<XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>" — path is field 7.
        let body = String(entry.dropFirst(2))
        let parts = body.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
        let xy = parts.first ?? ".."
        let path = parts.count > 7 ? parts[7] : ""
        return (xy, path)
    }

    private static func mapCode(_ c: Character) -> DiffStatus {
        switch c {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .unmerged
        default: return .modified
        }
    }
}

extension ISO8601DateFormatter {
    static let gitISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
