import Foundation

/// How far back / which refs to walk when loading commits.
public struct CommitQuery: Sendable {
    public enum Scope: Sendable {
        case head
        case branch(String)
        case ref(String)
        case all
    }
    public var repo: Repository
    public var scope: Scope
    public var maxCount: Int?
    public var skip: Int?
    public var since: Date?
    /// Case-insensitive, literal (non-regex) substring the commit *message* must contain. Filtering
    /// is done by git itself (`rev-list --grep`), so only matching commits are streamed — the walk
    /// stops once `maxCount` matches are found, bounding the cost on large histories.
    public var grep: String?

    public init(repo: Repository, scope: Scope = .head,
                maxCount: Int? = nil, skip: Int? = nil, since: Date? = nil, grep: String? = nil) {
        self.repo = repo
        self.scope = scope
        self.maxCount = maxCount
        self.skip = skip
        self.since = since
        self.grep = grep
    }
}

/// What two trees to diff.
public enum DiffRange: Sendable {
    case workingUnstaged
    case workingStaged
    /// An untracked file's full contents, rendered as an all-additions diff against nothing.
    /// Untracked files don't appear in `diff-files`, so they're surfaced explicitly by path.
    case workingUntracked(String)
    case commit(String)
    case between(String, String)
}

/// How many unchanged lines to show around each change. `standard` is git's default 3 lines;
/// `wholeFile` asks git for enough context that the entire file is shown around the changes.
public enum DiffContext: Sendable, Equatable {
    case standard
    case wholeFile

    /// The `--unified=<n>` value to pass to git. A very large number is clamped by git to the
    /// file length, so the whole file is emitted as one hunk.
    public var unifiedLines: Int {
        switch self {
        case .standard:  return 3
        case .wholeFile: return 1_000_000_000
        }
    }
}

public enum GitError: Error, Sendable {
    case gitNotFound
    case notARepository(URL)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case decodingFailed(String)
    case cancelled
}

/// The single seam between the rest of the app and git. Backed by the user's own git binary.
public protocol GitBackend: Sendable {
    func gitVersion() async throws -> String
    func openRepository(at url: URL) async throws -> Repository
    func loadCommits(_ query: CommitQuery) -> AsyncThrowingStream<Commit, Error>
    func commitCount(_ query: CommitQuery) async throws -> Int
    /// Resolve a revision string (a SHA prefix, tag, branch, `HEAD~3`, …) to a full commit SHA,
    /// or `nil` if it doesn't name a single unambiguous commit in this repo. Search uses this as
    /// its "exact match" leg, letting git decide what is a real ref/object instead of guessing.
    func resolveCommit(_ rev: String, in repo: Repository) async throws -> String?
    func refs(for repo: Repository) async throws -> RefSnapshot
    func diff(_ range: DiffRange, context: DiffContext, in repo: Repository) async throws -> [DiffFile]
    func workingCopyStatus(for repo: Repository) async throws -> WorkingCopyStatus
    func blob(at path: String, rev: String, in repo: Repository) async throws -> Data
    /// The git note attached to a commit in the default ref (`refs/notes/commits`), or nil.
    func note(for sha: String, in repo: Repository) async throws -> String?
    /// All `refs/notes/*` refs present in the repo. Empty when the repo has no notes at all.
    func noteRefs(for repo: Repository) async throws -> [String]
    /// The git note for a commit in a specific note ref, or nil if the commit has no note there.
    func note(for sha: String, ref: String, in repo: Repository) async throws -> String?
    /// A commit message git has genuinely prepared for an in-progress operation — read from
    /// `MERGE_MSG`/`SQUASH_MSG` in the git dir (merge/squash/cherry-pick). `nil` when none exists.
    /// Read-only; never written. (`COMMIT_EDITMSG` is intentionally not used — it lingers after
    /// every commit and would surface a stale message.)
    func preparedCommitMessage(for repo: Repository) async throws -> String?
    /// Line-level AI/human authorship for a commit from `refs/ai/authorship/<sha>` (git-ai format),
    /// or nil if the repo has no authorship data or the commit isn't annotated.
    func aiAuthorship(for sha: String, in repo: Repository) async throws -> AIAuthorshipRecord?
}

public extension GitBackend {
    /// Convenience for the common case of git's default context. Forwards to the context-aware
    /// requirement so existing callers (and test fakes) need not pass `.standard` explicitly.
    func diff(_ range: DiffRange, in repo: Repository) async throws -> [DiffFile] {
        try await diff(range, context: .standard, in: repo)
    }

    /// Default for backends without revision resolution (e.g. test fakes): no exact match.
    func resolveCommit(_ rev: String, in repo: Repository) async throws -> String? { nil }
    /// Default for backends without note support (e.g. test fakes): no note.
    func note(for sha: String, in repo: Repository) async throws -> String? { nil }
    /// Default: no note refs (e.g. test fakes).
    func noteRefs(for repo: Repository) async throws -> [String] { [] }
    /// Default: no issues (e.g. test fakes, repos without git-bug).
    func loadIssues(in repo: Repository) async throws -> [GitIssue] { [] }
    /// Default: delegates to the single-ref note method for the given ref (test fakes may skip).
    func note(for sha: String, ref: String, in repo: Repository) async throws -> String? { nil }
    /// Default for backends without working-copy message support (e.g. test fakes): none.
    func preparedCommitMessage(for repo: Repository) async throws -> String? { nil }
    /// Default: no authorship data (e.g. test fakes, repos without git-ai).
    func aiAuthorship(for sha: String, in repo: Repository) async throws -> AIAuthorshipRecord? { nil }
}
