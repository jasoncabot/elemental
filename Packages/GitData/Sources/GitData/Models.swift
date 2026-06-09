import Foundation

/// A git identity (author or committer).
public struct Signature: Hashable, Sendable {
    public var name: String
    public var email: String
    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

/// An on-disk worktree linked to a repository.
public struct Worktree: Hashable, Sendable {
    public var path: URL
    public var head: String?
    public var branch: String?
    public var isBare: Bool
    public var isDetached: Bool
    public var isLocked: Bool
    public var isPrunable: Bool
    public init(path: URL, head: String?, branch: String?, isBare: Bool,
                isDetached: Bool = false, isLocked: Bool = false, isPrunable: Bool = false) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

/// An opened repository. Identity is its on-disk location; refs are loaded separately.
public struct Repository: Hashable, Sendable, Identifiable {
    public var rootURL: URL
    public var gitDir: URL
    public var commonDir: URL
    public var isBare: Bool
    public var worktrees: [Worktree]

    public var id: URL { rootURL }

    public init(rootURL: URL, gitDir: URL, commonDir: URL, isBare: Bool, worktrees: [Worktree] = []) {
        self.rootURL = rootURL
        self.gitDir = gitDir
        self.commonDir = commonDir
        self.isBare = isBare
        self.worktrees = worktrees
    }
}

/// A commit. Identity is the SHA and is immutable; this is the stable key for all UI state.
public struct Commit: Hashable, Sendable, Identifiable {
    public var sha: String
    public var parents: [String]
    public var author: Signature
    public var committer: Signature
    public var authorDate: Date
    public var commitDate: Date
    public var subject: String
    public var body: String
    public var refNames: [String]

    public var id: String { sha }
    public var isMerge: Bool { parents.count > 1 }

    public init(sha: String, parents: [String], author: Signature, committer: Signature,
                authorDate: Date, commitDate: Date, subject: String, body: String,
                refNames: [String]) {
        self.sha = sha
        self.parents = parents
        self.author = author
        self.committer = committer
        self.authorDate = authorDate
        self.commitDate = commitDate
        self.subject = subject
        self.body = body
        self.refNames = refNames
    }
}

/// HEAD state: attached to a branch or detached at a SHA.
public enum HeadState: Hashable, Sendable {
    case attached(branch: String, sha: String)
    case detached(sha: String)
    case unborn(branch: String)

    public var sha: String? {
        switch self {
        case .attached(_, let sha), .detached(let sha): return sha
        case .unborn: return nil
        }
    }
}

public enum RefKind: Hashable, Sendable {
    case branch, remote, tag
}

/// A named ref pointing at a SHA. This is part of the *mutable* view layer over the SHA graph.
public struct Ref: Hashable, Sendable, Identifiable {
    public var name: String
    public var sha: String
    public var kind: RefKind
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?

    public var id: String { "\(kind):\(name)" }

    public init(name: String, sha: String, kind: RefKind,
                upstream: String? = nil, ahead: Int? = nil, behind: Int? = nil) {
        self.name = name
        self.sha = sha
        self.kind = kind
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }
}

/// A point-in-time snapshot of refs. Refreshed independently of SHA-keyed content.
public struct RefSnapshot: Sendable {
    public var head: HeadState
    public var branches: [Ref]
    public var remotes: [Ref]
    public var tags: [Ref]

    public init(head: HeadState, branches: [Ref], remotes: [Ref], tags: [Ref]) {
        self.head = head
        self.branches = branches
        self.remotes = remotes
        self.tags = tags
    }
}

public enum DiffStatus: Hashable, Sendable {
    case added, modified, deleted, renamed, copied, typeChanged, unmerged, untracked, ignored
}

public enum DiffLineKind: Hashable, Sendable {
    case context, added, removed
}

/// Structural classification of a *changed* line, produced by `DiffAnnotator` (heuristic, offline).
/// Lets the UI de-emphasise churn so substantive edits stand out. `.context` lines are always
/// `.substantive` — this only describes added/removed lines.
public enum DiffLineChange: Hashable, Sendable {
    case substantive   // a genuine content change (the default)
    case whitespace    // differs from its counterpart only in whitespace (reindent, trailing space)
    case moved         // this exact line appears on the opposite side elsewhere in the diff
}

public struct DiffLine: Hashable, Sendable {
    public var kind: DiffLineKind
    public var oldLineNumber: Int?
    public var newLineNumber: Int?
    public var text: String
    public var change: DiffLineChange
    public init(kind: DiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, text: String,
                change: DiffLineChange = .substantive) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
        self.change = change
    }
}

public struct DiffHunk: Hashable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// The raw `@@ -a,b +c,d @@ …` header line, verbatim.
    public var header: String
    /// The enclosing function/section git reports after the second `@@` (its xfuncname), cleaned
    /// up — e.g. `func handleLogin() {`. `nil` when git emits none (unsupported language, top of
    /// file). This is the free "which function changed?" rung.
    public var context: String?
    public var lines: [DiffLine]
    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
                header: String, lines: [DiffLine], context: String? = nil) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.header = header
        self.context = context
        self.lines = lines
    }
}

public struct DiffFile: Hashable, Sendable, Identifiable {
    public var oldPath: String?
    public var newPath: String?
    public var status: DiffStatus
    public var isBinary: Bool
    public var hunks: [DiffHunk]
    public var additions: Int
    public var deletions: Int

    public var id: String { (newPath ?? oldPath ?? "?") + ":" + String(describing: status) }
    public var displayPath: String { newPath ?? oldPath ?? "?" }

    public init(oldPath: String?, newPath: String?, status: DiffStatus, isBinary: Bool,
                hunks: [DiffHunk], additions: Int, deletions: Int) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
        self.isBinary = isBinary
        self.hunks = hunks
        self.additions = additions
        self.deletions = deletions
    }
}

/// A git-native issue stored in `refs/bugs/*` (git-bug format).
public struct GitIssue: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable { case open, closed }

    public var id: String          // short 7-char prefix of the bug SHA
    public var bugID: String       // full 64-char bug SHA (the ref suffix)
    public var title: String
    public var body: String        // from the CreateOp message
    public var status: Status
    public var createdAt: Date
    public var updatedAt: Date     // timestamp of the last operation in the chain
    public var labels: [String]
    public var commentCount: Int

    public var isOpen: Bool { status == .open }

    public init(id: String, bugID: String, title: String, body: String, status: Status,
                createdAt: Date, updatedAt: Date, labels: [String], commentCount: Int) {
        self.id = id
        self.bugID = bugID
        self.title = title
        self.body = body
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.labels = labels
        self.commentCount = commentCount
    }
}

/// A typed item in the review timeline. Commits are the primary kind; issues from git-bug
/// (`refs/bugs/*`) appear interleaved. The enum is the stable contract between
/// `TimelinePresenter` and the view — adding a new case is all that's needed for a new kind.
public enum TimelineItem: Identifiable, Sendable {
    case commit(Commit)
    case issue(GitIssue)

    public var id: String {
        switch self {
        case .commit(let c): return "commit:\(c.sha)"
        case .issue(let i): return "issue:\(i.bugID)"
        }
    }

    /// The SHA if this item is a commit, else nil.
    public var sha: String? {
        if case .commit(let c) = self { return c.sha } else { return nil }
    }

    /// The canonical timestamp for ordering items in the stream.
    public var timestamp: Date {
        switch self {
        case .commit(let c): return c.commitDate
        case .issue(let i): return i.updatedAt
        }
    }

    /// Convenience: the commit, or nil for other item kinds.
    public var commit: Commit? {
        if case .commit(let c) = self { return c } else { return nil }
    }

    /// Convenience: the issue, or nil for other item kinds.
    public var issue: GitIssue? {
        if case .issue(let i) = self { return i } else { return nil }
    }
}

/// A git trailer — a `Key: Value` line at the end of a commit body (RFC 5322 style).
/// Common examples: `Co-authored-by`, `Reviewed-by`, `Fixes`, `Closes`, `Signed-off-by`.
public struct CommitTrailer: Hashable, Sendable {
    public var key: String
    public var value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// A parsed Conventional Commits header (`feat(auth)!: add login`).
/// See <https://www.conventionalcommits.org/>.
public struct ConventionalCommit: Hashable, Sendable {
    public var type: String        // "feat", "fix", "chore", …
    public var scope: String?      // "auth", "api", … or nil
    public var isBreaking: Bool    // `!` before the colon, or `BREAKING CHANGE` trailer
    public var description: String // everything after `: `
    public init(type: String, scope: String?, isBreaking: Bool, description: String) {
        self.type = type
        self.scope = scope
        self.isBreaking = isBreaking
        self.description = description
    }
}

/// A detected reference to an external issue or ticket in commit text.
public struct IssueRef: Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        case numeric(Int)     // #123 — GitHub/GitLab style
        case prefixed(String) // JIRA-456, GH-789, LINEAR-123
    }
    public var raw: String   // the matched string as it appears in the text
    public var style: Style
    public init(raw: String, style: Style) {
        self.raw = raw
        self.style = style
    }
}

public extension Commit {
    /// Trailers parsed from the commit body (e.g. `Co-authored-by`, `Fixes`, `Reviewed-by`).
    var trailers: [CommitTrailer] { TrailerParser.parse(body) }
    /// Conventional Commits header parsed from the subject, or nil if the subject doesn't match.
    var conventional: ConventionalCommit? { ConventionalCommitParser.parse(subject) }
    /// Issue references detected in subject, body, and trailer values.
    var issueRefs: [IssueRef] { IssueRefParser.parse(subject: subject, body: body) }
    /// The commit body with the trailing trailer block stripped — the prose the author wrote.
    var bodyWithoutTrailers: String { TrailerParser.bodyWithoutTrailers(body) }
}

/// Line-level authorship record for a commit, read from `refs/ai/authorship/<sha>` (git-ai format).
/// Records which authors (human or AI agent) wrote which lines in each changed file.
public struct AIAuthorshipRecord: Hashable, Sendable {
    public struct FileRecord: Hashable, Sendable {
        public struct Author: Hashable, Sendable {
            public var name: String
            public var lineCount: Int
            public init(name: String, lineCount: Int) {
                self.name = name
                self.lineCount = lineCount
            }
        }
        public var path: String
        public var authors: [Author]
        public var totalLines: Int { authors.reduce(0) { $0 + $1.lineCount } }
        public init(path: String, authors: [Author]) {
            self.path = path
            self.authors = authors
        }
    }

    public var files: [FileRecord]
    public var schemaVersion: String

    /// Total lines per author name across all files.
    public var authorTotals: [String: Int] {
        var totals: [String: Int] = [:]
        for file in files {
            for author in file.authors {
                totals[author.name, default: 0] += author.lineCount
            }
        }
        return totals
    }

    public init(files: [FileRecord], schemaVersion: String = "") {
        self.files = files
        self.schemaVersion = schemaVersion
    }
}

/// A single file's status in the working copy.
public struct FileStatus: Hashable, Sendable, Identifiable {
    public var path: String
    public var originalPath: String?
    public var status: DiffStatus
    public var id: String { path }
    public init(path: String, originalPath: String? = nil, status: DiffStatus) {
        self.path = path
        self.originalPath = originalPath
        self.status = status
    }
}

public struct WorkingCopyStatus: Sendable {
    public var branch: String?
    public var ahead: Int?
    public var behind: Int?
    public var staged: [FileStatus]
    public var unstaged: [FileStatus]
    public var untracked: [FileStatus]
    public var conflicts: [FileStatus]

    public var isClean: Bool {
        staged.isEmpty && unstaged.isEmpty && untracked.isEmpty && conflicts.isEmpty
    }

    public init(branch: String?, ahead: Int?, behind: Int?, staged: [FileStatus],
                unstaged: [FileStatus], untracked: [FileStatus], conflicts: [FileStatus]) {
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicts = conflicts
    }
}
