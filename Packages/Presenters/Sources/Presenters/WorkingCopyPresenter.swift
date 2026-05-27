import Foundation
import GitData

/// Presents the working-copy status (staged / unstaged / untracked) and per-file diffs for one
/// repository. Subscribes to `RepoWatcher` — on dirty event sets `isDirty` (no auto-reload);
/// on user Refresh re-fetches status and any previously-loaded diff.
@MainActor
public final class WorkingCopyPresenter: Presenter {

    private let backend: GitBackend
    private let watcher: RepoWatcher
    private let repo: Repository

    public private(set) var status: WorkingCopyStatus?
    public private(set) var selectedFile: FileStatus.ID?
    /// Which area the selected file lives in (staged vs unstaged).
    public private(set) var selectedArea: DiffRange?
    /// The diff for the currently-selected file.
    public private(set) var diff: [DiffFile] = []
    public private(set) var isDirty = false
    public private(set) var isLoadingStatus = false
    public private(set) var isLoadingDiff = false
    public private(set) var lastStatusError: Error?
    public private(set) var lastDiffError: Error?

    private var statusTask:   Task<Void, Never>?
    private var diffTask:     Task<Void, Never>?
    private var watchTask:    Task<Void, Never>?
    private var diffGeneration: Int = 0

    public init(backend: GitBackend, watcher: RepoWatcher, repo: Repository) {
        self.backend = backend
        self.watcher = watcher
        self.repo = repo
        super.init()
    }

    // MARK: – Public API

    public func start() {
        observeDiskChanges()
        loadStatus()
    }

    /// Select a file in a specific area (`.workingStaged` or `.workingUnstaged`) and load its diff.
    public func selectFile(id: FileStatus.ID?, area: DiffRange?) {
        selectedFile = id
        selectedArea = area
        diff = []
        guard id != nil, let area else { notify(); return }
        loadDiff(range: area)
    }

    /// Called by the view when the user clicks the Refresh affordance.
    public func refresh() {
        isDirty = false
        loadStatus()
        // Re-load diff if a file was selected.
        if let area = selectedArea {
            loadDiff(range: area)
        }
    }

    // MARK: – Private helpers

    private func observeDiskChanges() {
        watchTask = Task { [weak self, watcher, repo] in
            for await _ in watcher.events(for: repo) {
                guard let self else { return }
                // Do NOT auto-reload. Surface the banner; keep current state on screen.
                self.isDirty = true
                self.notify()
            }
        }
    }

    private func loadStatus() {
        statusTask?.cancel()
        isLoadingStatus = true
        lastStatusError = nil
        notify()

        statusTask = Task { [weak self, backend, repo] in
            guard let self else { return }
            do {
                let result = try await backend.workingCopyStatus(for: repo)
                if Task.isCancelled { return }
                self.status = result
                self.isLoadingStatus = false
                // If the selected file no longer appears in the new status, clear it.
                self.reconcileSelection(with: result)
            } catch is CancellationError {
                return
            } catch {
                self.isLoadingStatus = false
                self.lastStatusError = error
            }
            self.notify()
        }
    }

    private func loadDiff(range: DiffRange) {
        diffTask?.cancel()
        diffGeneration &+= 1
        let generation = diffGeneration
        isLoadingDiff = true
        lastDiffError = nil
        diff = []
        notify()

        diffTask = Task { [weak self, backend, repo] in
            guard let self else { return }
            do {
                let result = try await backend.diff(range, in: repo)
                if Task.isCancelled { return }
                // Only apply if a newer diff request hasn't superseded this one.
                guard self.diffGeneration == generation else { return }
                self.diff = result
                self.isLoadingDiff = false
            } catch is CancellationError {
                return
            } catch {
                guard self.diffGeneration == generation else { return }
                self.isLoadingDiff = false
                self.lastDiffError = error
            }
            self.notify()
        }
    }

    private func reconcileSelection(with newStatus: WorkingCopyStatus) {
        guard let id = selectedFile else { return }
        let allFiles = newStatus.staged + newStatus.unstaged + newStatus.untracked + newStatus.conflicts
        if !allFiles.contains(where: { $0.id == id }) {
            selectedFile = nil
            selectedArea = nil
            diff = []
        }
    }

    deinit {
        statusTask?.cancel()
        diffTask?.cancel()
        watchTask?.cancel()
    }
}
