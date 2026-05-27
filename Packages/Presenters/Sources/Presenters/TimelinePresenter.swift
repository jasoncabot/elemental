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
    /// Row index in the table where commits[0] lives. Zero on initial load; nonzero after a jump.
    public private(set) var baseOffset: Int = 0
    public private(set) var selectedSHA: String?
    public private(set) var isDirty = false
    public private(set) var isLoading = false
    public private(set) var hasMoreCommits = true
    public private(set) var totalCommitCount: Int? = nil
    public private(set) var lastError: Error?

    private var indexBySHA: [String: Int] = [:]
    private var query: CommitQuery
    private let pageSize: Int
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    public init(backend: GitBackend, watcher: RepoWatcher, repo: Repository,
                scope: CommitQuery.Scope = .head, pageSize: Int = 200) {
        self.backend = backend
        self.watcher = watcher
        self.repo = repo
        self.pageSize = pageSize
        self.query = CommitQuery(repo: repo, scope: scope, maxCount: pageSize)
        super.init()
    }

    public func start() {
        observeDiskChanges()
        reload()
        fetchTotalCount()
    }

    public func setScope(_ scope: CommitQuery.Scope) {
        query = CommitQuery(repo: repo, scope: scope, maxCount: query.maxCount)
        totalCommitCount = nil
        reload()
        fetchTotalCount()
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
        totalCommitCount = nil
        reload(preservingSelection: true)
        fetchTotalCount()
    }

    // MARK: - Pagination

    /// Load the next page sequentially from the end of the currently loaded window.
    public func loadMore() {
        guard !isLoading && hasMoreCommits else { return }
        let skip = baseOffset + commits.count
        appendPage(skip: skip)
    }

    /// Load commits at or near `row`, jumping the loaded window if the row is far from the
    /// current window. Sequential calls (row within the next page) behave like loadMore().
    public func loadFrom(row: Int) {
        let pageStart = max(0, (row / pageSize) * pageSize)
        let loadedEnd = baseOffset + commits.count

        // Sequential: the row is in the next page boundary — standard append.
        if pageStart >= baseOffset && pageStart < loadedEnd + pageSize {
            loadMore()
            return
        }

        // Jump: cancel whatever is running and start fresh from this offset.
        resetAndLoad(from: pageStart)
    }

    // MARK: - Private loading

    private func appendPage(skip: Int) {
        let pageSize = self.pageSize
        let nextQuery = CommitQuery(repo: repo, scope: query.scope, maxCount: pageSize, skip: skip)
        isLoading = true
        notify()
        loadTask = Task { [weak self, backend, nextQuery, pageSize] in
            guard let self else { return }
            var page: [Commit] = []
            do {
                for try await commit in backend.loadCommits(nextQuery) {
                    page.append(commit)
                }
            } catch is CancellationError { return }
            catch {
                self.isLoading = false
                self.notify()
                return
            }
            if Task.isCancelled { return }
            if page.count < pageSize { self.hasMoreCommits = false }
            let startIndex = self.commits.count
            self.commits.append(contentsOf: page)
            for (i, c) in page.enumerated() {
                self.indexBySHA[c.sha] = startIndex + i
            }
            self.isLoading = false
            self.notify()
        }
    }

    private func resetAndLoad(from pageStart: Int) {
        loadTask?.cancel()
        commits = []
        indexBySHA = [:]
        baseOffset = pageStart
        hasMoreCommits = true
        isLoading = true
        notify()

        let pageSize = self.pageSize
        let q = CommitQuery(repo: repo, scope: query.scope, maxCount: pageSize, skip: pageStart)
        loadTask = Task { [weak self, backend, q, pageSize] in
            guard let self else { return }
            var page: [Commit] = []
            do {
                for try await commit in backend.loadCommits(q) {
                    page.append(commit)
                }
            } catch is CancellationError { return }
            catch {
                self.isLoading = false
                self.notify()
                return
            }
            if Task.isCancelled { return }
            if page.count < pageSize { self.hasMoreCommits = false }
            self.commits = page
            self.indexBySHA = Dictionary(
                uniqueKeysWithValues: page.enumerated().map { ($1.sha, $0) })
            self.isLoading = false
            self.notify()
        }
    }

    private func observeDiskChanges() {
        watchTask = Task { [weak self, watcher, repo] in
            for await _ in watcher.events(for: repo) {
                guard let self else { return }
                self.isDirty = true
                self.notify()
            }
        }
    }

    private func fetchTotalCount() {
        let q = CommitQuery(repo: repo, scope: query.scope)
        Task { [weak self, backend, q] in
            guard let self else { return }
            let count = try? await backend.commitCount(q)
            self.totalCommitCount = count
            self.notify()
        }
    }

    private func reload(preservingSelection: Bool = false) {
        hasMoreCommits = true
        baseOffset = 0
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
        if let previousSelection, indexBySHA[previousSelection] != nil {
            selectedSHA = previousSelection
        } else if let previousSelection, !newCommits.isEmpty {
            selectedSHA = newCommits.first?.sha
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
