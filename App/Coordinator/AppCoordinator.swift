import AppKit
import GitData
import Presenters

/// Composition root and navigation hub.
/// Builds the toolbar + three panes (timeline / files / diff), wires the bookmark
/// store, and routes selection across panes. Presenters and views never talk to each
/// other directly — everything passes through here.
@MainActor
final class AppCoordinator {
    // MARK: - Owned objects

    private let backend: any GitBackend
    private let watcher: any RepoWatcher
    private let bookmarkStore: RepoBookmarkStore

    let windowController: MainWindowController

    private let toolbarController = ToolbarController()
    private let timelineVC = TimelineViewController()
    private let filesVC = FilesViewController()
    private let diffVC = DiffViewController()

    // MARK: - Per-repo presenter caches (keyed by repo root URL)

    private var timelinePresenters: [URL: TimelinePresenter] = [:]
    private var commitDetailPresenters: [URL: CommitDetailPresenter] = [:]
    private var workingCopyPresenters: [URL: WorkingCopyPresenter] = [:]
    private var watcherTasks: [URL: Task<Void, Never>] = [:]
    private var branchTasks: [URL: Task<Void, Never>] = [:]
    private(set) var activeRepoURL: URL?
    /// Count of in-flight `addRepository` tasks. `start()` defers its fallback selection until
    /// all pending adds resolve so a CLI-supplied path wins over the last-known repo.
    private var pendingAddCount = 0
    /// Which source currently drives the detail panes (a commit, or the working copy), so file
    /// selections from the files pane route to the right presenter.
    private var activeDetailSource: (any DetailSource)?

    // MARK: - Init

    init(backend: any GitBackend, watcher: any RepoWatcher) {
        self.backend = backend
        self.watcher = watcher
        self.bookmarkStore = RepoBookmarkStore(backend: backend)

        self.windowController = MainWindowController(
            toolbarController: toolbarController,
            timelineVC: timelineVC,
            filesVC: filesVC,
            diffVC: diffVC
        )

        toolbarController.delegate = self
        timelineVC.delegate = self
        filesVC.delegate = self
        filesVC.reviewMode = toolbarController.reviewMode

        windowController.onDropFolders = { [weak self] urls in
            urls.forEach { self?.addRepository(at: $0) }
        }

        bookmarkStore.onRepositoriesChanged = { [weak self] in
            self?.refreshRepoList()
        }
    }

    // MARK: - Public API (called by AppDelegate)

    func removeCurrentRepository() {
        guard let url = activeRepoURL,
              let repo = bookmarkStore.repositories.first(where: { $0.rootURL == url }) else { return }
        removeRepo(repo)
    }

    func addRepository(at url: URL) {
        pendingAddCount += 1
        Task {
            defer { pendingAddCount -= 1 }
            do {
                let repo = try await bookmarkStore.add(url: url)
                selectRepo(repo.rootURL)
            } catch {
                presentNotARepoAlert(for: url)
            }
        }
    }

    func start() async {
        await bookmarkStore.restoreOnLaunch()
        // If a folder was already opened via `el <path>` / Finder (application(_:open:)), it has
        // set the active repo and wins — don't override it. If an add is still in flight (the Task
        // from addRepository hasn't resolved yet), also stand down — it will call selectRepo itself.
        guard activeRepoURL == nil, pendingAddCount == 0 else { return }
        let repos = bookmarkStore.repositories
        let lastActive = UserDefaults.standard.string(forKey: Self.lastActiveRepoKey)
        if let lastActive, let match = repos.first(where: { $0.rootURL.path == lastActive }) {
            selectRepo(match.rootURL)
        } else if let first = repos.first {
            selectRepo(first.rootURL)
        }
    }

    /// UserDefaults key for the most recently active repo, restored on the next plain launch.
    private static let lastActiveRepoKey = "lastActiveRepoPath"

    // MARK: - Repo list / selection

    private func refreshRepoList() {
        let choices = bookmarkStore.repositories.map {
            RepoChoice(id: $0.rootURL, title: $0.rootURL.lastPathComponent)
        }
        toolbarController.setRepos(choices, selected: activeRepoURL)
    }

    private func selectRepo(_ url: URL?) {
        guard let url,
              let repo = bookmarkStore.repositories.first(where: { $0.rootURL == url }) else {
            activeRepoURL = nil
            activeDetailSource = nil
            timelineVC.presenter = nil
            timelineVC.workingCopyPresenter = nil
            filesVC.source = nil
            diffVC.source = nil
            toolbarController.setBranch(nil)
            return
        }

        activeRepoURL = url
        // Remember this as the repo to restore on the next plain launch.
        UserDefaults.standard.set(url.path, forKey: Self.lastActiveRepoKey)
        refreshRepoList()
        loadBranch(for: repo)

        let timeline: TimelinePresenter
        if let existing = timelinePresenters[url] {
            timeline = existing
        } else {
            let p = TimelinePresenter(backend: backend, watcher: watcher, repo: repo)
            timelinePresenters[url] = p
            timeline = p
            p.start()
            startWatching(repo)
        }

        let detail: CommitDetailPresenter
        if let existing = commitDetailPresenters[url] {
            detail = existing
        } else {
            detail = CommitDetailPresenter(backend: backend, repo: repo)
            commitDetailPresenters[url] = detail
        }

        let workingCopy: WorkingCopyPresenter
        if let existing = workingCopyPresenters[url] {
            workingCopy = existing
        } else {
            let p = WorkingCopyPresenter(backend: backend, watcher: watcher, repo: repo)
            workingCopyPresenters[url] = p
            workingCopy = p
            p.start()
        }

        timelineVC.presenter = timeline
        timelineVC.workingCopyPresenter = workingCopy
        // Default to reviewing the selected commit; the working-copy row is opt-in.
        activeDetailSource = detail
        filesVC.source = detail
        diffVC.source = detail
        let initialCommit = timeline.selectedSHA.flatMap { timeline.commit(for: $0) }
        detail.show(commit: initialCommit)
    }

    private func loadBranch(for repo: Repository) {
        branchTasks[repo.rootURL]?.cancel()
        branchTasks[repo.rootURL] = Task { [weak self, backend] in
            guard let snapshot = try? await backend.refs(for: repo) else { return }
            guard let self, self.activeRepoURL == repo.rootURL else { return }
            let branch: String?
            switch snapshot.head {
            case .attached(let b, _): branch = b
            case .unborn(let b):      branch = b
            case .detached(let sha):  branch = String(sha.prefix(7))
            }
            self.toolbarController.setBranch(branch)
        }
    }

    // MARK: - Watcher-based auto-removal and branch refresh

    /// Paths within the git dir that, when changed, indicate HEAD or branch ref has moved.
    private static let headRelatedPaths: [String] = ["HEAD", "refs/heads/", "packed-refs"]

    private func startWatching(_ repo: Repository) {
        watcherTasks[repo.rootURL] = Task { [weak self, watcher, repo] in
            for await event in watcher.events(for: repo) {
                guard let self else { return }
                if !FileManager.default.fileExists(atPath: repo.rootURL.path) {
                    self.removeRepo(repo)
                    return
                }
                // If the changed paths indicate a branch switch or HEAD move,
                // automatically refresh the branch name in the toolbar (lightweight).
                if self.activeRepoURL == repo.rootURL {
                    let isHeadChange = event.changedPaths.contains { path in
                        Self.headRelatedPaths.contains(where: { path.hasSuffix($0) || path.contains($0) })
                    }
                    if isHeadChange {
                        self.loadBranch(for: repo)
                    }
                }
            }
        }
    }

    private func removeRepo(_ repo: Repository) {
        let url = repo.rootURL
        watcherTasks.removeValue(forKey: url)?.cancel()
        branchTasks.removeValue(forKey: url)?.cancel()
        timelinePresenters.removeValue(forKey: url)
        commitDetailPresenters.removeValue(forKey: url)
        workingCopyPresenters.removeValue(forKey: url)
        bookmarkStore.remove(repo: repo)
        if activeRepoURL == url {
            selectRepo(bookmarkStore.repositories.first?.rootURL)
        }
    }

    // MARK: - Alerts

    private func presentNotARepoAlert(for url: URL) {
        let alert = NSAlert()
        alert.messageText = "Not a Git Repository"
        alert.informativeText = "\(url.lastPathComponent) does not appear to be a git repository."
        alert.alertStyle = .warning
        if let window = windowController.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }
}

// MARK: - ToolbarControllerDelegate

extension AppCoordinator: ToolbarControllerDelegate {
    func toolbarDidSelectRepo(_ url: URL) { selectRepo(url) }

    func toolbarDidChangeReviewMode(_ mode: ReviewMode) { filesVC.reviewMode = mode }

    func toolbarDidChangeSearch(_ query: String) { filesVC.filter = query }
}

// MARK: - TimelineViewControllerDelegate

extension AppCoordinator: TimelineViewControllerDelegate {
    func timelineViewController(_ vc: TimelineViewController, didSelectSHA sha: String?) {
        vc.presenter?.select(sha)
        guard let url = activeRepoURL, let detail = commitDetailPresenters[url] else { return }
        let commit = sha.flatMap { vc.presenter?.commit(for: $0) }
        detail.show(commit: commit)
        // Route the detail panes back to commit review.
        activeDetailSource = detail
        filesVC.source = detail
        diffVC.source = detail
    }

    func timelineViewControllerDidSelectWorkingCopy(_ vc: TimelineViewController) {
        guard let url = activeRepoURL, let workingCopy = workingCopyPresenters[url] else { return }
        activeDetailSource = workingCopy
        filesVC.source = workingCopy
        diffVC.source = workingCopy
    }

    func timelineViewControllerDidRequestRefresh(_ vc: TimelineViewController) {
        vc.presenter?.refresh()
        // Refresh the working copy too, so its row counts and diffs reflect the new on-disk state.
        if let url = activeRepoURL { workingCopyPresenters[url]?.refresh() }
    }
}

// MARK: - FilesViewControllerDelegate

extension AppCoordinator: FilesViewControllerDelegate {
    func filesViewController(_ vc: FilesViewController, didSelect selection: DetailSelection?) {
        // Route to whichever source currently drives the panes (commit or working copy).
        activeDetailSource?.select(selection)
    }
}
