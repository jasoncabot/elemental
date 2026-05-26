import Foundation
import GitData

/// Owns the commit timeline for one repo+scope. State is keyed by SHA so on-disk ref changes
/// can't invalidate what's displayed — only a deliberate Refresh reconciles the ref view.
@MainActor
public final class TimelinePresenter: Presenter {
    private let backend: GitBackend
    private let watcher: RepoWatcher
    private let repo: Repository

    public private(set) var commits: [Commit] = []
    public private(set) var selectedSHA: String?
    public private(set) var isDirty = false
    public private(set) var isLoading = false
    public private(set) var lastError: Error?

    private var indexBySHA: [String: Int] = [:]
    private var query: CommitQuery
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    public init(backend: GitBackend, watcher: RepoWatcher, repo: Repository,
                scope: CommitQuery.Scope = .head, pageSize: Int = 200) {
        self.backend = backend
        self.watcher = watcher
        self.repo = repo
        self.query = CommitQuery(repo: repo, scope: scope, maxCount: pageSize)
        super.init()
    }

    public func start() {
        observeDiskChanges()
        reload()
    }

    public func setScope(_ scope: CommitQuery.Scope) {
        query = CommitQuery(repo: repo, scope: scope, maxCount: query.maxCount)
        reload()
    }

    public func select(_ sha: String?) {
        selectedSHA = sha
        notify()
    }

    public func commit(for sha: String) -> Commit? {
        indexBySHA[sha].map { commits[$0] }
    }

    /// Called by the view when the user clicks the Refresh affordance after a dirty signal.
    public func refresh() {
        isDirty = false
        reload(preservingSelection: true)
    }

    private func observeDiskChanges() {
        watchTask = Task { [weak self, watcher, repo] in
            for await _ in watcher.events(for: repo) {
                guard let self else { return }
                // Do NOT auto-reload. Surface the banner; keep current SHA-keyed state on screen.
                self.isDirty = true
                self.notify()
            }
        }
    }

    private func reload(preservingSelection: Bool = false) {
        let previousSelection = preservingSelection ? selectedSHA : nil
        loadTask?.cancel()
        isLoading = true
        lastError = nil
        notify()

        loadTask = Task { [weak self, backend, query] in
            guard let self else { return }
            var collected: [Commit] = []
            do {
                for try await commit in backend.loadCommits(query) {
                    collected.append(commit)
                }
            } catch is CancellationError {
                return
            } catch {
                self.isLoading = false
                self.lastError = error
                self.notify()
                return
            }
            if Task.isCancelled { return }
            self.apply(collected, previousSelection: previousSelection)
        }
    }

    private func apply(_ newCommits: [Commit], previousSelection: String?) {
        commits = newCommits
        indexBySHA = Dictionary(uniqueKeysWithValues: newCommits.enumerated().map { ($1.sha, $0) })
        // Reconcile selection: keep it if the SHA survived; otherwise fall back gracefully.
        if let previousSelection, indexBySHA[previousSelection] != nil {
            selectedSHA = previousSelection
        } else if let previousSelection, !newCommits.isEmpty {
            selectedSHA = newCommits.first?.sha     // nearest reachable from new HEAD
            _ = previousSelection
        } else if selectedSHA == nil {
            selectedSHA = newCommits.first?.sha
        } else if indexBySHA[selectedSHA!] == nil {
            selectedSHA = newCommits.first?.sha
        }
        isLoading = false
        notify()
    }

    deinit {
        loadTask?.cancel()
        watchTask?.cancel()
    }
}
