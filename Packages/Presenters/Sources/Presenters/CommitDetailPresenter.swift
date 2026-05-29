import Foundation
import GitData

/// Loads and caches the diff for a selected commit. SHA is immutable, so cached diffs never go
/// stale and survive on-disk ref changes without refetching.
@MainActor
public final class CommitDetailPresenter: Presenter {
    public enum Mode: Sendable { case unified, sideBySide }

    /// Loading state of a commit's git note. Distinguishes "still fetching" from "no note exists"
    /// — a plain `String?` collapses those into the same `nil`.
    public enum NoteState: Sendable, Equatable {
        case loading           // fetch in flight; result not yet known
        case loaded(String)    // the commit has a note
        case unavailable       // fetch finished: the commit has no note (or it couldn't be read)
    }

    private let backend: GitBackend
    private let repo: Repository

    public private(set) var sha: String?
    /// The commit being reviewed — its message is the "why" behind the diff.
    public private(set) var commit: Commit?
    /// The commit's git note (refs/notes/commits), fetched on demand.
    public private(set) var commitNote: NoteState = .unavailable
    /// Load state of the commit's diff — the single source of truth for files/loading/error.
    public private(set) var filesState: Loadable<[DiffFile]> = .idle
    public private(set) var selectedFile: DiffFile.ID?
    public private(set) var mode: Mode = .unified

    public var files: [DiffFile] { filesState.value ?? [] }
    public var isLoading: Bool { filesState.isLoading }
    public var lastError: Error? { filesState.error }

    private var cache: [String: [DiffFile]] = [:]
    private var loadTask: Task<Void, Never>?

    public init(backend: GitBackend, repo: Repository) {
        self.backend = backend
        self.repo = repo
        super.init()
    }

    public func show(commit: Commit?) {
        let sha = commit?.sha
        guard sha != self.sha else { return }
        self.sha = sha
        self.commit = commit
        guard let commit else {
            commitNote = .unavailable
            filesState = .idle; selectedFile = nil; notify(); return
        }
        commitNote = .loading
        fetchNote(for: commit.sha)
        if let cached = cache[commit.sha] {
            filesState = .loaded(cached)
            selectedFile = cached.first?.id
            notify()
            return
        }
        load(commit)
    }

    /// Loads the commit's git note in the background; the message panel updates if/when it arrives.
    private func fetchNote(for sha: String) {
        Task { [weak self, backend, repo, sha] in
            let note = (try? await backend.note(for: sha, in: repo)) ?? nil
            guard let self, self.sha == sha else { return }
            self.commitNote = note.map(NoteState.loaded) ?? .unavailable
            self.notify()
        }
    }

    public func selectFile(_ id: DiffFile.ID?) {
        selectedFile = id
        notify()
    }

    /// Switch inline ↔ side-by-side. No reload needed; the view re-renders the same diff.
    public func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        notify()
    }

    private func load(_ commit: Commit) {
        let sha = commit.sha
        // Merge commits produce an empty "combined diff" via git show; diff against
        // the first parent instead to show what the merge actually brought in.
        let range: DiffRange = commit.isMerge && !commit.parents.isEmpty
            ? .between(commit.parents[0], sha)
            : .commit(sha)

        loadTask?.cancel()
        filesState = .loading
        notify()
        loadTask = Task { [weak self, backend, repo, sha, range] in
            guard let self else { return }
            do {
                let result = try await backend.diff(range, in: repo)
                if Task.isCancelled { return }
                self.cache[sha] = result
                guard self.sha == sha else { return }
                self.filesState = .loaded(result)
                self.selectedFile = result.first?.id
                self.notify()
            } catch is CancellationError {
                return
            } catch {
                guard self.sha == sha else { return }
                self.filesState = .failed(error)
                self.notify()
            }
        }
    }

    deinit { loadTask?.cancel() }
}
