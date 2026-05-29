import Foundation
import GitData

/// Presents the working copy as the three trees git actually tracks — **staged** (index vs HEAD),
/// **unstaged** (worktree vs index), and **untracked** — kept as distinct, first-class views rather
/// than collapsed into one "changes" blob. The staged/unstaged diffs are loaded eagerly so the
/// files pane can show both side by side (a file edited in both appears in both); untracked file
/// contents load lazily on selection. Read-only: it reflects staging the user performs elsewhere.
///
/// Subscribes to `RepoWatcher` — on a dirty event it sets `isDirty` (no auto-reload); the user's
/// Refresh re-fetches everything.
@MainActor
public final class WorkingCopyPresenter: Presenter {

    private let backend: GitBackend
    private let watcher: RepoWatcher
    private let repo: Repository

    /// The selected file's path within its area. A path can exist in two areas (staged *and*
    /// unstaged), so selection is meaningful only together with `selectedArea`.
    public private(set) var selectedFile: FileStatus.ID?
    /// Which area the selected file lives in: `.workingStaged`, `.workingUnstaged`, or
    /// `.workingUntracked(path)`.
    public private(set) var selectedArea: DiffRange?
    public private(set) var isDirty = false

    /// Single source of truth for the working-copy status (file lists + branch + ahead/behind).
    public private(set) var statusState: Loadable<WorkingCopyStatus> = .idle
    /// Staged diff (`git diff --cached`), loaded eagerly. Drives the "Staged" section + its diffs.
    public private(set) var stagedState: Loadable<[DiffFile]> = .idle
    /// Unstaged diff (`git diff`), loaded eagerly. Drives the "Unstaged" section + its diffs.
    public private(set) var unstagedState: Loadable<[DiffFile]> = .idle
    /// The currently-selected untracked file's contents, loaded lazily (all-additions diff).
    public private(set) var untrackedState: Loadable<[DiffFile]> = .idle
    /// git's prepared commit message (MERGE_MSG/SQUASH_MSG/COMMIT_EDITMSG), if any. The "why"
    /// floor for uncommitted work — there is no SHA to hang a git note on yet.
    public private(set) var preparedMessage: String?
    /// Inline vs side-by-side rendering for the diff pane. Shared shape with `CommitDetailPresenter`
    /// so a single header toggle drives whichever detail source is active.
    public var mode: CommitDetailPresenter.Mode = .unified

    public var status: WorkingCopyStatus? { statusState.value }
    public var stagedFiles: [DiffFile] { stagedState.value ?? [] }
    public var unstagedFiles: [DiffFile] { unstagedState.value ?? [] }
    public var isLoadingStatus: Bool { statusState.isLoading }
    public var lastStatusError: Error? { statusState.error }

    /// All files in the currently-selected area (the diff pane picks `selectedDiffFile` from these).
    public var diff: [DiffFile] {
        switch selectedArea {
        case .workingStaged:    return stagedFiles
        case .workingUnstaged:  return unstagedFiles
        case .workingUntracked: return untrackedState.value ?? []
        default:                return []
        }
    }
    public var isLoadingDiff: Bool {
        switch selectedArea {
        case .workingStaged:    return stagedState.isLoading
        case .workingUnstaged:  return unstagedState.isLoading
        case .workingUntracked: return untrackedState.isLoading
        default:                return false
        }
    }
    public var lastDiffError: Error? {
        switch selectedArea {
        case .workingStaged:    return stagedState.error
        case .workingUnstaged:  return unstagedState.error
        case .workingUntracked: return untrackedState.error
        default:                return nil
        }
    }
    /// The single `DiffFile` to render for the current selection, resolved by path within its area.
    public var selectedDiffFile: DiffFile? {
        guard let id = selectedFile else { return nil }
        return diff.first { $0.displayPath == id }
    }

    private var statusTask:    Task<Void, Never>?
    private var stagedTask:    Task<Void, Never>?
    private var unstagedTask:  Task<Void, Never>?
    private var untrackedTask: Task<Void, Never>?
    private var watchTask:     Task<Void, Never>?

    public init(backend: GitBackend, watcher: RepoWatcher, repo: Repository) {
        self.backend = backend
        self.watcher = watcher
        self.repo = repo
        super.init()
    }

    // MARK: – Public API

    public func start() {
        observeDiskChanges()
        reloadAll()
    }

    /// Switch inline ↔ side-by-side. No reload needed; the view re-renders the same diff.
    public func setMode(_ mode: CommitDetailPresenter.Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        notify()
    }

    /// Select a file in a specific area. Staged/unstaged diffs are already loaded eagerly; only an
    /// untracked file triggers a load (its contents aren't part of any tree diff).
    public func selectFile(id: FileStatus.ID?, area: DiffRange?) {
        selectedFile = id
        selectedArea = area
        untrackedState = .idle
        untrackedTask?.cancel()
        guard id != nil, let area else { notify(); return }
        if case .workingUntracked(let path) = area {
            loadUntracked(path: path)
        } else {
            notify()
        }
    }

    /// Called by the view when the user clicks the Refresh affordance.
    public func refresh() {
        isDirty = false
        reloadAll()
        if case .workingUntracked(let path)? = selectedArea {
            loadUntracked(path: path)
        }
    }

    // MARK: – Private helpers

    private func reloadAll() {
        loadStatus()
        loadStaged()
        loadUnstaged()
        loadPreparedMessage()
    }

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
        statusState = .loading
        notify()

        statusTask = Task { [weak self, backend, repo] in
            guard let self else { return }
            do {
                let result = try await backend.workingCopyStatus(for: repo)
                if Task.isCancelled { return }
                self.statusState = .loaded(result)
                // If the selected file no longer appears in the new status, clear it.
                self.reconcileSelection(with: result)
            } catch is CancellationError {
                return
            } catch {
                self.statusState = .failed(error)
            }
            self.notify()
        }
    }

    private func loadStaged() {
        stagedTask?.cancel()
        stagedState = .loading
        notify()
        stagedTask = Task { [weak self, backend, repo] in
            guard let self else { return }
            do {
                let result = try await backend.diff(.workingStaged, in: repo)
                if Task.isCancelled { return }
                self.stagedState = .loaded(result)
            } catch is CancellationError { return }
            catch { self.stagedState = .failed(error) }
            self.notify()
        }
    }

    private func loadUnstaged() {
        unstagedTask?.cancel()
        unstagedState = .loading
        notify()
        unstagedTask = Task { [weak self, backend, repo] in
            guard let self else { return }
            do {
                let result = try await backend.diff(.workingUnstaged, in: repo)
                if Task.isCancelled { return }
                self.unstagedState = .loaded(result)
            } catch is CancellationError { return }
            catch { self.unstagedState = .failed(error) }
            self.notify()
        }
    }

    private func loadUntracked(path: String) {
        untrackedTask?.cancel()
        untrackedState = .loading
        notify()
        untrackedTask = Task { [weak self, backend, repo] in
            guard let self else { return }
            do {
                let result = try await backend.diff(.workingUntracked(path), in: repo)
                if Task.isCancelled { return }
                // Ignore a stale load if the selection moved on while this was in flight.
                guard case .workingUntracked(path)? = self.selectedArea else { return }
                self.untrackedState = .loaded(result)
            } catch is CancellationError { return }
            catch {
                guard case .workingUntracked(path)? = self.selectedArea else { return }
                self.untrackedState = .failed(error)
            }
            self.notify()
        }
    }

    private func loadPreparedMessage() {
        Task { [weak self, backend, repo] in
            let message = try? await backend.preparedCommitMessage(for: repo)
            guard let self else { return }
            self.preparedMessage = message ?? nil
            self.notify()
        }
    }

    private func reconcileSelection(with newStatus: WorkingCopyStatus) {
        guard let id = selectedFile else { return }
        let allFiles = newStatus.staged + newStatus.unstaged + newStatus.untracked + newStatus.conflicts
        if !allFiles.contains(where: { $0.id == id }) {
            selectedFile = nil
            selectedArea = nil
            untrackedState = .idle
        }
    }

    deinit {
        statusTask?.cancel()
        stagedTask?.cancel()
        unstagedTask?.cancel()
        untrackedTask?.cancel()
        watchTask?.cancel()
    }
}
