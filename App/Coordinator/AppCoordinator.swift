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
    private var watcherTasks: [URL: Task<Void, Never>] = [:]
    private var branchTasks: [URL: Task<Void, Never>] = [:]
    private var activeRepoURL: URL?

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

    func addRepository(at url: URL) {
        Task {
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
        if activeRepoURL == nil, let first = bookmarkStore.repositories.first {
            selectRepo(first.rootURL)
        }
    }

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
            timelineVC.presenter = nil
            filesVC.presenter = nil
            diffVC.presenter = nil
            toolbarController.setBranch(nil)
            return
        }

        activeRepoURL = url
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

        timelineVC.presenter = timeline
        filesVC.presenter = detail
        diffVC.presenter = detail
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

    // MARK: - Watcher-based auto-removal

    private func startWatching(_ repo: Repository) {
        watcherTasks[repo.rootURL] = Task { [weak self, watcher, repo] in
            for await _ in watcher.events(for: repo) {
                guard let self else { return }
                if !FileManager.default.fileExists(atPath: repo.rootURL.path) {
                    self.removeRepo(repo)
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
        if let url = activeRepoURL {
            let commit = sha.flatMap { vc.presenter?.commit(for: $0) }
            commitDetailPresenters[url]?.show(commit: commit)
        }
    }

    func timelineViewControllerDidRequestRefresh(_ vc: TimelineViewController) {
        vc.presenter?.refresh()
    }
}

// MARK: - FilesViewControllerDelegate

extension AppCoordinator: FilesViewControllerDelegate {
    func filesViewController(_ vc: FilesViewController, didSelectFile id: DiffFile.ID?) {
        guard let url = activeRepoURL else { return }
        commitDetailPresenters[url]?.selectFile(id)
    }
}
