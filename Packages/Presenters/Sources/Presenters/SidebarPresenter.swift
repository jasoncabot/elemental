import Foundation
import GitData

/// Manages the list of open repositories and per-repo ref snapshots. Selection of a repo and
/// ref scope drives the timeline. The coordinator injects the repo list; this presenter owns
/// ref loading and grouping.
@MainActor
public final class SidebarPresenter: Presenter {

    public struct RepoItem: Sendable {
        public let repo: Repository
        public var refs: RefSnapshot?
        public var isLoadingRefs: Bool
        public var refError: Error?

        public var branches: [Ref] { refs?.branches ?? [] }
        public var remotes:  [Ref] { refs?.remotes  ?? [] }
        public var tags:     [Ref] { refs?.tags      ?? [] }

        public init(repo: Repository) {
            self.repo = repo
            self.refs = nil
            self.isLoadingRefs = false
            self.refError = nil
        }
    }

    /// The scope selected in the sidebar — drives `TimelinePresenter`.
    public enum Selection: Sendable, Equatable {
        case allCommits(Repository)
        case branch(Repository, String)
        case remote(Repository, String)
        case tag(Repository, String)
    }

    private let backend: GitBackend
    private let watcher: RepoWatcher

    public private(set) var items: [RepoItem] = []
    public private(set) var selection: Selection?
    public private(set) var isDirty = false

    /// Per-repo in-flight ref-load tasks; keyed by repo root URL.
    private var refLoadTasks: [URL: Task<Void, Never>] = [:]
    /// Per-repo watcher tasks.
    private var watchTasks:   [URL: Task<Void, Never>] = [:]

    public init(backend: GitBackend, watcher: RepoWatcher) {
        self.backend = backend
        self.watcher = watcher
        super.init()
    }

    // MARK: – Public API

    /// Replace the full repo list (called by coordinator when the bookmark store changes).
    public func setRepositories(_ repos: [Repository]) {
        // Stop watching repos that were removed.
        let newIDs = Set(repos.map(\.rootURL))
        for id in watchTasks.keys where !newIDs.contains(id) {
            watchTasks.removeValue(forKey: id)?.cancel()
            refLoadTasks.removeValue(forKey: id)?.cancel()
        }

        // Build items, carrying over any already-loaded RefSnapshot.
        let existing = Dictionary(uniqueKeysWithValues: items.map { ($0.repo.rootURL, $0) })
        items = repos.map { repo in existing[repo.rootURL] ?? RepoItem(repo: repo) }

        // Kick off watcher + ref load for any new repos.
        for repo in repos where watchTasks[repo.rootURL] == nil {
            startWatching(repo)
            loadRefs(for: repo)
        }

        // If the current selection's repo was removed, clear it.
        if let sel = selection, !newIDs.contains(selectionRepo(sel).rootURL) {
            selection = nil
        }

        notify()
    }

    public func select(_ selection: Selection?) {
        self.selection = selection
        notify()
    }

    /// Called by the view when the user confirms the dirty-banner Refresh.
    public func refresh() {
        isDirty = false
        for item in items { loadRefs(for: item.repo) }
    }

    // MARK: – Private helpers

    private func selectionRepo(_ sel: Selection) -> Repository {
        switch sel {
        case .allCommits(let r), .branch(let r, _), .remote(let r, _), .tag(let r, _): return r
        }
    }

    private func startWatching(_ repo: Repository) {
        watchTasks[repo.rootURL] = Task { [weak self, watcher, repo] in
            for await _ in watcher.events(for: repo) {
                guard let self else { return }
                // Do NOT auto-reload — surface the dirty banner only.
                self.isDirty = true
                self.notify()
            }
        }
    }

    private func loadRefs(for repo: Repository) {
        refLoadTasks[repo.rootURL]?.cancel()
        updateItem(repo: repo) { $0.isLoadingRefs = true; $0.refError = nil }
        notify()

        refLoadTasks[repo.rootURL] = Task { [weak self, backend, repo] in
            guard let self else { return }
            do {
                let snapshot = try await backend.refs(for: repo)
                if Task.isCancelled { return }
                self.updateItem(repo: repo) {
                    $0.refs = snapshot
                    $0.isLoadingRefs = false
                    $0.refError = nil
                }
            } catch is CancellationError {
                return
            } catch {
                self.updateItem(repo: repo) {
                    $0.isLoadingRefs = false
                    $0.refError = error
                }
            }
            self.notify()
        }
    }

    private func updateItem(repo: Repository, mutate: (inout RepoItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.repo.rootURL == repo.rootURL }) else { return }
        mutate(&items[idx])
    }

    deinit {
        refLoadTasks.values.forEach { $0.cancel() }
        watchTasks.values.forEach   { $0.cancel() }
    }
}
