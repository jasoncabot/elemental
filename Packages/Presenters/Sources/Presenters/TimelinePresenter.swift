import Foundation
import GitData

/// Owns the commit timeline for one repo+scope as a **sparse, paged data source**.
///
/// The full row count is fetched once (`git rev-list --count`); individual pages of commits are
/// loaded on demand as the view asks for rows via `commit(atRow:)`. Nothing is ever "appended" —
/// any row in the history can be requested directly and the surrounding page is fetched with a
/// `skip`/`maxCount` query. This lets the table virtualise millions of rows: only the handful of
/// pages overlapping the viewport are ever resident, and an LRU cap bounds memory.
///
/// State is keyed by SHA so on-disk ref changes can't invalidate what's displayed — only a
/// deliberate Refresh reconciles the ref view.
@MainActor
public final class TimelinePresenter: Presenter {
    private let backend: GitBackend
    private let watcher: RepoWatcher
    private let repo: Repository

    /// Total number of commits in scope. `nil` until the count query returns.
    public private(set) var totalCommitCount: Int? = nil
    public private(set) var selectedSHA: String?
    public private(set) var isDirty = false
    public private(set) var lastError: Error?

    /// Number of rows the view should display. During a search this is the bounded result count;
    /// otherwise it falls back to the contiguous loaded prefix while the authoritative count is
    /// still being fetched, so the first page shows immediately.
    public var rowCount: Int {
        if let searchResults { return searchResults.count }
        return totalCommitCount ?? contiguousLoadedCount
    }

    private var query: CommitQuery
    private let pageSize: Int
    /// Most pages we keep resident before evicting least-recently-used ones.
    private let maxResidentPages: Int

    private var pages: [Int: [Commit]] = [:]
    private var pageTasks: [Int: Task<Void, Never>] = [:]
    private var pageAccessOrder: [Int] = []        // LRU: most-recent at the end
    private var commitBySHA: [String: Commit] = [:]
    private var rowBySHA: [String: Int] = [:]
    /// Selected commit pinned across page eviction so detail review survives scrolling away.
    private var pinnedSelected: Commit?

    private var countTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var isCounting = false

    // MARK: - Search
    //
    // When a search is active the timeline switches from the paged history to a *bounded* result
    // set: an exact match (`rev-parse` of the query as a SHA prefix / tag / branch / revision) is
    // unioned with the message matches (`rev-list --grep`), deduped, exact first. The paged backing
    // is left untouched so clearing the search restores browsing instantly, without a git reload.

    /// The active result set, or `nil` while browsing the normal paged history.
    private var searchResults: [Commit]?
    /// Trimmed text currently driving the search; empty while browsing.
    public private(set) var searchQuery: String = ""
    /// A short human summary for the timeline's search strip ("12 results…"), or `nil` while browsing.
    public private(set) var searchSummary: String?
    private var searchTask: Task<Void, Never>?
    /// The browsing selection captured when search began, restored when the search is cleared.
    private var preSearchSelectedSHA: String?
    /// Hard cap on results so a broad query can't stream unbounded matches into memory.
    private let searchResultLimit = 100
    /// Debounce so each keystroke doesn't spawn a git walk; the prior in-flight search is cancelled.
    private let searchDebounce: Duration = .milliseconds(250)

    /// Whether a search is currently filtering the timeline (text present, regardless of result count).
    public var isSearchActive: Bool { !searchQuery.isEmpty }
    /// After a refresh that preserves selection, the kept SHA is reconciled against the first page
    /// once it loads: if it's no longer reachable, the selection falls back to the tip.
    private var reconcileSelectionOnFirstPage = false

    public init(backend: GitBackend, watcher: RepoWatcher, repo: Repository,
                scope: CommitQuery.Scope = .head, pageSize: Int = 200, maxResidentPages: Int = 32) {
        self.backend = backend
        self.watcher = watcher
        self.repo = repo
        self.pageSize = pageSize
        self.maxResidentPages = maxResidentPages
        self.query = CommitQuery(repo: repo, scope: scope, maxCount: pageSize)
        super.init()
    }

    public func start() {
        observeDiskChanges()
        reload(preservingSelection: false)
    }

    public func setScope(_ scope: CommitQuery.Scope) {
        cancelSearch()
        query = CommitQuery(repo: repo, scope: scope, maxCount: pageSize)
        reload(preservingSelection: false)
    }

    public func select(_ sha: String?) {
        selectedSHA = sha
        if let sha, let c = commitBySHA[sha] { pinnedSelected = c }
        notify()
    }

    /// Called by the view when the user clicks the Refresh affordance after a dirty signal.
    public func refresh() {
        isDirty = false
        let active = searchQuery
        reload(preservingSelection: true)
        // Re-run any active search against the freshly reloaded state.
        if !active.isEmpty {
            searchResults = nil
            searchQuery = ""
            setSearch(active)
        }
    }

    // MARK: - Search

    /// Drive the timeline from the search field. Empty input restores the paged history. Each call
    /// debounces and supersedes the previous in-flight search.
    public func setSearch(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != searchQuery else { return }
        searchTask?.cancel()

        if trimmed.isEmpty {
            clearSearch()
            return
        }
        // Capture the browsing selection the first time we enter search, so clearing restores it.
        if searchResults == nil { preSearchSelectedSHA = selectedSHA }
        searchQuery = trimmed
        let scope = query.scope
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: self?.searchDebounce ?? .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await self.runSearch(trimmed, scope: scope)
        }
    }

    private func runSearch(_ raw: String, scope: CommitQuery.Scope) async {
        var results: [Commit] = []
        var seen = Set<String>()

        // Exact leg: does the query name a single commit (SHA prefix, tag, branch, revision)?
        if let sha = try? await backend.resolveCommit(raw, in: repo),
           let commit = await firstCommit(scope: .ref(sha)) {
            results.append(commit)
            seen.insert(commit.sha)
        }
        guard !Task.isCancelled, searchQuery == raw else { return }

        // Message leg: commits whose message contains the text. git filters and stops at the cap.
        let grepQuery = CommitQuery(repo: repo, scope: scope, maxCount: searchResultLimit, grep: raw)
        do {
            for try await c in backend.loadCommits(grepQuery) {
                if Task.isCancelled || searchQuery != raw { return }
                if seen.insert(c.sha).inserted { results.append(c) }
                if results.count >= searchResultLimit { break }
            }
        } catch is CancellationError {
            return
        } catch {
            // A failed grep walk just yields whatever matched; nothing fatal to surface here.
        }
        guard !Task.isCancelled, searchQuery == raw else { return }
        applyResults(results, for: raw)
    }

    /// The first commit of a one-row query (used to fetch the exact-match commit object by SHA).
    private func firstCommit(scope: CommitQuery.Scope) async -> Commit? {
        let q = CommitQuery(repo: repo, scope: scope, maxCount: 1)
        do {
            for try await c in backend.loadCommits(q) { return c }
        } catch {
            return nil
        }
        return nil
    }

    private func applyResults(_ results: [Commit], for raw: String) {
        searchResults = results
        searchTask = nil
        searchSummary = Self.searchSummary(count: results.count, limit: searchResultLimit, query: raw)
        // Auto-select the first match so the diff opens immediately (a SHA jumps straight to it).
        if let first = results.first {
            selectedSHA = first.sha
            pinnedSelected = first
        } else {
            selectedSHA = nil
        }
        notify()
    }

    private func clearSearch() {
        let wasActive = searchResults != nil || !searchQuery.isEmpty
        cancelSearch()
        guard wasActive else { return }
        // Restore the pre-search browsing selection if it's still cached; else fall back to the tip.
        if let sha = preSearchSelectedSHA {
            selectedSHA = sha
            if let c = commitBySHA[sha] { pinnedSelected = c }
        } else if selectedSHA == nil {
            selectedSHA = pages[0]?.first?.sha
        }
        preSearchSelectedSHA = nil
        notify()
    }

    /// Tear down search state without notifying (callers notify or reload as appropriate).
    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchResults = nil
        searchSummary = nil
        searchQuery = ""
    }

    private static func searchSummary(count: Int, limit: Int, query: String) -> String {
        if count == 0 { return "No commits match “\(query)”" }
        if count >= limit { return "Showing first \(limit) — refine to narrow" }
        return "\(count) result\(count == 1 ? "" : "s") for “\(query)”"
    }

    // MARK: - Sparse access (the view's data source)

    /// The commit at an absolute row, or `nil` if its page isn't resident yet. On a miss the
    /// surrounding page is scheduled and observers are notified when it arrives.
    public func commit(atRow row: Int) -> Commit? {
        if let searchResults {
            return (row >= 0 && row < searchResults.count) ? searchResults[row] : nil
        }
        guard row >= 0 else { return nil }
        if let total = totalCommitCount, row >= total { return nil }
        let page = row / pageSize
        if let commits = pages[page] {
            touch(page: page)
            let idx = row % pageSize
            return idx < commits.count ? commits[idx] : nil
        }
        ensurePageLoaded(page)
        return nil
    }

    /// The commit at a row only if it is *already* resident — never schedules a page load. Used by
    /// the view's row-height pass, which must touch every queried row without perturbing the paged
    /// working set (which would defeat virtualisation).
    public func residentCommit(atRow row: Int) -> Commit? {
        if let searchResults {
            return (row >= 0 && row < searchResults.count) ? searchResults[row] : nil
        }
        guard row >= 0 else { return nil }
        if let total = totalCommitCount, row >= total { return nil }
        guard let commits = pages[row / pageSize] else { return nil }
        let idx = row % pageSize
        return idx < commits.count ? commits[idx] : nil
    }

    /// Absolute row of a SHA, if it currently lives in a resident page (or the search results).
    public func row(forSHA sha: String) -> Int? {
        if let searchResults { return searchResults.firstIndex { $0.sha == sha } }
        return rowBySHA[sha]
    }

    /// Ensure the pages overlapping `range` are loaded. Used by custom views (the dot strip) that
    /// don't request individual rows the way the table does.
    public func prefetch(rows range: Range<Int>) {
        guard !range.isEmpty else { return }
        let firstPage = max(0, range.lowerBound) / pageSize
        let lastPage = max(0, range.upperBound - 1) / pageSize
        guard lastPage >= firstPage else { return }
        for page in firstPage...lastPage { ensurePageLoaded(page) }
    }

    /// A commit by SHA if cached (search results, resident page, or the pinned selection), else `nil`.
    public func commit(for sha: String) -> Commit? {
        if let searchResults, let c = searchResults.first(where: { $0.sha == sha }) { return c }
        return commitBySHA[sha] ?? (pinnedSelected?.sha == sha ? pinnedSelected : nil)
    }

    // MARK: - Compatibility surface (used by tests + simple callers)

    /// Loading is in progress while the count or any page is in flight.
    public var isLoading: Bool { isCounting || !pageTasks.isEmpty }

    /// The contiguous run of commits loaded from row 0. For repos that fit in one page this is the
    /// whole history; larger histories expose only what's resident from the top.
    public var commits: [Commit] {
        var result: [Commit] = []
        var page = 0
        while let p = pages[page] {
            result.append(contentsOf: p)
            if p.count < pageSize { break }
            page += 1
        }
        return result
    }

    /// Whether more commits exist beyond the contiguous loaded prefix.
    public var hasMoreCommits: Bool {
        if let total = totalCommitCount { return contiguousLoadedCount < total }
        return true
    }

    // MARK: - Page loading

    private var contiguousLoadedCount: Int {
        var count = 0
        var page = 0
        while let p = pages[page] {
            count += p.count
            if p.count < pageSize { break }
            page += 1
        }
        return count
    }

    private func ensurePageLoaded(_ page: Int) {
        guard pages[page] == nil, pageTasks[page] == nil else { return }
        let skip = page * pageSize
        let q = CommitQuery(repo: repo, scope: query.scope, maxCount: pageSize, skip: skip)
        pageTasks[page] = Task { [weak self, backend, q] in
            var loaded: [Commit] = []
            do {
                for try await commit in backend.loadCommits(q) { loaded.append(commit) }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.pageTasks[page] = nil
                self.lastError = error
                self.notify()
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.store(page: page, commits: loaded)
        }
    }

    private func store(page: Int, commits: [Commit]) {
        pages[page] = commits
        for (i, c) in commits.enumerated() {
            let row = page * pageSize + i
            rowBySHA[c.sha] = row
            commitBySHA[c.sha] = c
        }
        pageTasks[page] = nil
        touch(page: page)
        evictIfNeeded()

        if page == 0 {
            // Reconcile selection against the freshly loaded tip page.
            if reconcileSelectionOnFirstPage {
                reconcileSelectionOnFirstPage = false
                if let sha = selectedSHA, commitBySHA[sha] == nil {
                    selectedSHA = nil   // kept selection is gone — fall back to tip below
                }
            }
            if selectedSHA == nil, let first = commits.first {
                selectedSHA = first.sha
                pinnedSelected = first
            }
        }
        notify()
    }

    /// Mark a page as most-recently used.
    private func touch(page: Int) {
        pageAccessOrder.removeAll { $0 == page }
        pageAccessOrder.append(page)
    }

    private func evictIfNeeded() {
        while pageAccessOrder.count > maxResidentPages {
            let victim = pageAccessOrder.removeFirst()
            guard let commits = pages.removeValue(forKey: victim) else { continue }
            for c in commits where c.sha != selectedSHA {
                rowBySHA.removeValue(forKey: c.sha)
                commitBySHA.removeValue(forKey: c.sha)
            }
        }
    }

    // MARK: - Reload / count

    private func reload(preservingSelection: Bool) {
        let keptSelection = preservingSelection ? selectedSHA : nil
        pageTasks.values.forEach { $0.cancel() }
        pageTasks = [:]
        countTask?.cancel()
        pages = [:]
        pageAccessOrder = []
        rowBySHA = [:]
        commitBySHA = [:]
        totalCommitCount = nil
        lastError = nil
        if !preservingSelection { selectedSHA = nil; pinnedSelected = nil }
        else { selectedSHA = keptSelection }
        reconcileSelectionOnFirstPage = preservingSelection && keptSelection != nil
        fetchCount()
        ensurePageLoaded(0)
        notify()
    }

    private func fetchCount() {
        let q = CommitQuery(repo: repo, scope: query.scope)
        isCounting = true
        countTask = Task { [weak self, backend, q] in
            let count = try? await backend.commitCount(q)
            guard let self, !Task.isCancelled else { return }
            self.isCounting = false
            self.totalCommitCount = count ?? 0
            self.notify()
        }
    }

    // MARK: - Disk watching

    private func observeDiskChanges() {
        watchTask = Task { [weak self, watcher, repo] in
            for await event in watcher.events(for: repo) {
                guard let self else { return }
                // Only mark dirty when the commit graph may have changed. Changes to
                // `.git/index` (e.g. `git status` stat-refresh) don't affect history.
                let isTimelineChange = event.changedPaths.contains { path in
                    if path == ".git" || path.hasSuffix("/.git") { return true }
                    return Self.timelineRelatedPaths.contains(where: {
                        path.hasSuffix($0) || path.contains($0)
                    })
                }
                guard isTimelineChange else { continue }
                self.isDirty = true
                self.notify()
            }
        }
    }

    // Paths whose modification signals a potential commit-graph change.
    // "HEAD" as a suffix catches ORIG_HEAD, MERGE_HEAD, CHERRY_PICK_HEAD, etc.
    private static let timelineRelatedPaths: [String] = [
        "HEAD", "refs/", "packed-refs", "logs/",
    ]

    deinit {
        countTask?.cancel()
        watchTask?.cancel()
        searchTask?.cancel()
        pageTasks.values.forEach { $0.cancel() }
    }
}
