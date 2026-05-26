import AppKit
import GitData
import Presenters

/// Composition root and navigation hub.
/// Creates the window + view controllers, wires the bookmark store, and routes
/// selection events across panes. All cross-pane navigation passes through here;
/// presenters and views never talk to each other directly.
@MainActor
final class AppCoordinator {
    // MARK: - Owned objects

    private let backend: any GitBackend
    private let watcher: any RepoWatcher
    private let bookmarkStore: RepoBookmarkStore

    let windowController: MainWindowController

    // MARK: - Child view controllers

    private let sidebarVC: SidebarViewController
    private let commitListVC: CommitListViewController
    private let detailVC: DetailViewController

    // MARK: - Per-repo presenter cache (keyed by repo root URL)
    // We keep alive timeline presenters so paging state survives sidebar re-selection.

    private var timelinePresenters: [URL: TimelinePresenter] = [:]

    // MARK: - Init

    init(backend: any GitBackend, watcher: any RepoWatcher) {
        self.backend = backend
        self.watcher = watcher
        self.bookmarkStore = RepoBookmarkStore(backend: backend)

        // Build view controllers
        self.sidebarVC = SidebarViewController()
        self.commitListVC = CommitListViewController()
        self.detailVC = DetailViewController()

        // Build window controller
        self.windowController = MainWindowController(
            sidebarVC: sidebarVC,
            commitListVC: commitListVC,
            detailVC: detailVC
        )

        // Wire delegates (coordinator is the hub)
        sidebarVC.delegate = self
        commitListVC.delegate = self

        // Bookmark store change handler
        bookmarkStore.onRepositoriesChanged = { [weak self] in
            self?.refreshSidebar()
        }
    }

    // MARK: - Public API (called by AppDelegate)

    /// Validates and adds a repository by URL (e.g. from File > Open Repository).
    func addRepository(at url: URL) {
        // Reuse the same validation + persist path as drag-in.
        sidebarViewController(sidebarVC, didDropFolderAt: url)
    }

    // MARK: - Launch

    func start() async {
        await bookmarkStore.restoreOnLaunch()
        windowController.showWindow(nil)
    }

    // MARK: - Sidebar refresh

    private func refreshSidebar() {
        sidebarVC.items = bookmarkStore.repositories.map { repo in
            SidebarItem(
                id: repo.rootURL,
                title: repo.rootURL.lastPathComponent,
                kind: .repoGroup(rootPath: repo.rootURL.path)
            )
        }
    }
}

// MARK: - SidebarViewControllerDelegate

extension AppCoordinator: SidebarViewControllerDelegate {
    func sidebarViewController(_ vc: SidebarViewController, didDropFolderAt url: URL) {
        Task {
            do {
                try await bookmarkStore.add(url: url)
            } catch {
                // Present a non-modal alert (best effort)
                let alert = NSAlert()
                alert.messageText = "Not a Git Repository"
                alert.informativeText = "\(url.lastPathComponent) does not appear to be a git repository."
                alert.alertStyle = .warning
                if let window = windowController.window {
                    await alert.beginSheetModal(for: window)
                }
            }
        }
    }

    func sidebarViewController(_ vc: SidebarViewController, didRemoveRepoAt url: URL) {
        guard let repo = bookmarkStore.repositories.first(where: { $0.rootURL == url }) else { return }
        timelinePresenters.removeValue(forKey: url)
        bookmarkStore.remove(repo: repo)
        commitListVC.presenter = nil
        detailVC.showCommit(sha: nil)
    }

    func sidebarViewController(_ vc: SidebarViewController, didSelectRepo url: URL?) {
        guard let url,
              let repo = bookmarkStore.repositories.first(where: { $0.rootURL == url }) else {
            commitListVC.presenter = nil
            detailVC.showCommit(sha: nil)
            return
        }

        // Reuse or create the timeline presenter for this repo
        let presenter: TimelinePresenter
        if let existing = timelinePresenters[url] {
            presenter = existing
        } else {
            let p = TimelinePresenter(backend: backend, watcher: watcher, repo: repo)
            timelinePresenters[url] = p
            presenter = p
            p.start()
        }
        commitListVC.presenter = presenter
        detailVC.showCommit(sha: presenter.selectedSHA)
    }
}

// MARK: - CommitListViewControllerDelegate

extension AppCoordinator: CommitListViewControllerDelegate {
    func commitListViewController(_ vc: CommitListViewController, didSelectSHA sha: String?) {
        detailVC.showCommit(sha: sha)
        // Also forward to the active presenter so it tracks selection
        vc.presenter?.select(sha)
    }

    func commitListViewControllerDidRequestRefresh(_ vc: CommitListViewController) {
        vc.presenter?.refresh()
    }
}
