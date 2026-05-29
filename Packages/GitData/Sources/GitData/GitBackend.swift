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

    public init(repo: Repository, scope: Scope = .head,
                maxCount: Int? = nil, skip: Int? = nil, since: Date? = nil) {
        self.repo = repo
        self.scope = scope
        self.maxCount = maxCount
        self.skip = skip
        self.since = since
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
    func refs(for repo: Repository) async throws -> RefSnapshot
    func diff(_ range: DiffRange, in repo: Repository) async throws -> [DiffFile]
    func workingCopyStatus(for repo: Repository) async throws -> WorkingCopyStatus
    func blob(at path: String, rev: String, in repo: Repository) async throws -> Data
    /// The git note attached to a commit (`refs/notes/commits`), or nil if it has none.
    func note(for sha: String, in repo: Repository) async throws -> String?
    /// A commit message git has genuinely prepared for an in-progress operation — read from
    /// `MERGE_MSG`/`SQUASH_MSG` in the git dir (merge/squash/cherry-pick). `nil` when none exists.
    /// Read-only; never written. (`COMMIT_EDITMSG` is intentionally not used — it lingers after
    /// every commit and would surface a stale message.)
    func preparedCommitMessage(for repo: Repository) async throws -> String?
}

public extension GitBackend {
    /// Default for backends without note support (e.g. test fakes): no note.
    func note(for sha: String, in repo: Repository) async throws -> String? { nil }
    /// Default for backends without working-copy message support (e.g. test fakes): none.
    func preparedCommitMessage(for repo: Repository) async throws -> String? { nil }
}
