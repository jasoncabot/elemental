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

public struct DiffLine: Hashable, Sendable {
    public var kind: DiffLineKind
    public var oldLineNumber: Int?
    public var newLineNumber: Int?
    public var text: String
    public init(kind: DiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, text: String) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

public struct DiffHunk: Hashable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var header: String
    public var lines: [DiffLine]
    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
                header: String, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.header = header
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
