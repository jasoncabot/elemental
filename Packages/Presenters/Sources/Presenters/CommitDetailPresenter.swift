import Foundation
import GitData

/// Loads and caches the diff for a selected commit. SHA is immutable, so cached diffs never go
/// stale and survive on-disk ref changes without refetching.
@MainActor
public final class CommitDetailPresenter: Presenter {
    public enum Mode: Sendable { case unified, sideBySide }

    /// A note from a specific git note ref (e.g. `refs/notes/commits`, `refs/notes/review`).
    public struct NoteEntry: Sendable, Equatable {
        /// Full ref name, e.g. `refs/notes/commits`.
        public var ref: String
        /// Human-readable short name (everything after `refs/notes/`).
        public var name: String
        /// Content of the note — always `.loaded` for entries the presenter exposes
        /// (entries with no note are simply omitted from the array).
        public var text: String
        public init(ref: String, text: String) {
            self.ref = ref
            self.name = ref.hasPrefix("refs/notes/")
                ? String(ref.dropFirst("refs/notes/".count))
                : ref
            self.text = text
        }
    }

    private let backend: GitBackend
    private let repo: Repository

    public private(set) var sha: String?
    /// The commit being reviewed — its message is the "why" behind the diff.
    public private(set) var commit: Commit?
    /// Notes attached to this commit across all available note refs, ordered by ref name.
    /// Only entries with an actual note text are included (no empty placeholders).
    public private(set) var commitNotes: [NoteEntry] = []
    /// Line-level AI/human authorship for the selected commit, or nil when unavailable.
    public private(set) var aiAuthorship: AIAuthorshipRecord?
    /// Cached list of `refs/notes/*` refs in the repo, loaded once per presenter lifetime.
    private var noteRefsCache: [String]?
    /// Load state of the commit's diff — the single source of truth for files/loading/error.
    public private(set) var filesState: Loadable<[DiffFile]> = .idle
    public private(set) var selectedFile: DiffFile.ID?
    public private(set) var mode: Mode = .unified
    public private(set) var diffContext: DiffContext = .standard

    public var repoRootURL: URL { repo.rootURL }
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
            commitNotes = []
            aiAuthorship = nil
            filesState = .idle; selectedFile = nil; notify(); return
        }
        commitNotes = []
        aiAuthorship = nil
        fetchNotes(for: commit.sha)
        fetchAIAuthorship(for: commit.sha)
        if let cached = cache[cacheKey(commit.sha)] {
            filesState = .loaded(cached)
            selectedFile = cached.first?.id
            notify()
            return
        }
        load(commit)
    }

    /// Discovers available note refs (once, cached) then fetches the note for this SHA from each.
    private func fetchNotes(for sha: String) {
        Task { [weak self, backend, repo, sha] in
            // Load the list of note refs lazily — one subprocess, cached for the presenter's life.
            let refs: [String]
            if let cached = self?.noteRefsCache {
                refs = cached
            } else {
                let loaded = (try? await backend.noteRefs(for: repo)) ?? []
                self?.noteRefsCache = loaded
                refs = loaded
            }

            guard !refs.isEmpty else {
                guard let self, self.sha == sha else { return }
                self.commitNotes = []
                self.notify()
                return
            }

            // Fetch each note sequentially — rare to have more than 2-3 refs.
            var entries: [NoteEntry] = []
            for ref in refs {
                if let text = try? await backend.note(for: sha, ref: ref, in: repo),
                   !text.isEmpty {
                    entries.append(NoteEntry(ref: ref, text: text))
                }
            }
            guard let self, self.sha == sha else { return }
            self.commitNotes = entries
            self.notify()
        }
    }

    private func fetchAIAuthorship(for sha: String) {
        Task { [weak self, backend, repo, sha] in
            let record = try? await backend.aiAuthorship(for: sha, in: repo)
            guard let self, self.sha == sha else { return }
            self.aiAuthorship = record
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

    /// Switch between standard and whole-file context. Unlike `setMode`, this needs a refetch
    /// (git emits different hunks), so it preserves the current selection and reloads.
    public func setDiffContext(_ context: DiffContext) {
        guard context != diffContext else { return }
        diffContext = context
        guard let commit else { notify(); return }
        let keepSelection = selectedFile
        if let cached = cache[cacheKey(commit.sha)] {
            filesState = .loaded(cached)
            selectedFile = cached.contains(where: { $0.id == keepSelection }) ? keepSelection
                                                                              : cached.first?.id
            notify()
            return
        }
        load(commit, keepSelection: keepSelection)
    }

    private func cacheKey(_ sha: String) -> String {
        "\(sha)#\(diffContext == .wholeFile ? "full" : "std")"
    }

    private func load(_ commit: Commit, keepSelection: DiffFile.ID? = nil) {
        let sha = commit.sha
        // Merge commits produce an empty "combined diff" via git show; diff against
        // the first parent instead to show what the merge actually brought in.
        let range: DiffRange = commit.isMerge && !commit.parents.isEmpty
            ? .between(commit.parents[0], sha)
            : .commit(sha)
        let context = diffContext
        let key = cacheKey(sha)

        loadTask?.cancel()
        filesState = .loading
        notify()
        loadTask = Task { [weak self, backend, repo, sha, range, context, key] in
            guard let self else { return }
            do {
                let result = try await backend.diff(range, context: context, in: repo)
                if Task.isCancelled { return }
                self.cache[key] = result
                guard self.sha == sha else { return }
                self.filesState = .loaded(result)
                self.selectedFile = result.contains(where: { $0.id == keepSelection })
                    ? keepSelection : result.first?.id
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

    /// Returns the blob for the most meaningful version of a file at this commit:
    /// the after-side for added/modified/renamed files, the before-side for deletions.
    public func currentBlob(for file: DiffFile) async -> Data? {
        if file.status == .deleted {
            guard let parentSHA = commit?.parents.first else { return nil }
            return try? await backend.blob(
                at: file.oldPath ?? file.displayPath, rev: parentSHA, in: repo)
        }
        guard let sha else { return nil }
        return try? await backend.blob(at: file.displayPath, rev: sha, in: repo)
    }

    /// Returns the raw bytes for the before/after sides of a binary file diff.
    /// Callers should pass the result to `NSImage(data:)` for rendering.
    public func imagePreviews(for file: DiffFile) async -> (before: Data?, after: Data?) {
        let afterData: Data?
        if let sha, file.status != .deleted {
            afterData = try? await backend.blob(at: file.displayPath, rev: sha, in: repo)
        } else {
            afterData = nil
        }
        let beforeData: Data?
        if let parentSHA = commit?.parents.first, file.status != .added {
            beforeData = try? await backend.blob(
                at: file.oldPath ?? file.displayPath, rev: parentSHA, in: repo)
        } else {
            beforeData = nil
        }
        return (beforeData, afterData)
    }

    deinit { loadTask?.cancel() }
}
