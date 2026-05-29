import AppKit
import GitData
import Presenters

/// The seam between the right-hand panes (files + diff) and whatever they're reviewing. Both the
/// commit detail presenter and the working-copy presenter conform, so the coordinator can swap
/// which one drives the panes without the views knowing the difference. Defined in the App target
/// (not the Presenters package) because it vends `FileAnalysis`/`ReviewMode`, which are App types.
@MainActor
protocol DetailSource: AnyObject {
    func addObserver(_ observer: PresenterObserving)
    func removeObserver(_ observer: PresenterObserving)

    /// The summary shown above the file list (commit message, or working-copy counts + draft).
    var header: DetailHeader { get }
    /// Files grouped for the middle pane. For commits these are subsystems; for the working copy
    /// they are the Staged / Unstaged / Untracked trees.
    func sections(reviewMode: ReviewMode) -> [DetailSection]

    var selection: DetailSelection? { get }
    func select(_ selection: DetailSelection?)

    /// The file to render in the diff pane, plus an area badge ("STAGED"/"UNSTAGED"/"NEW") or nil
    /// for commit review.
    var selectedDiff: (file: DiffFile, areaBadge: String?)? { get }

    var diffMode: CommitDetailPresenter.Mode { get }
    func setDiffMode(_ mode: CommitDetailPresenter.Mode)

    var isLoading: Bool { get }
    var lastError: Error? { get }
}

/// Which working-copy tree a file's changes belong to. Drives section grouping, the diff-pane
/// badge, and selection identity (a path can appear in two areas at once).
enum DetailArea: Hashable {
    case staged, unstaged, untracked

    var sectionTitle: String {
        switch self {
        case .staged:    return "Staged"
        case .unstaged:  return "Unstaged"
        case .untracked: return "Untracked"
        }
    }

    /// Short badge shown in the diff header for the file being read.
    var badge: String {
        switch self {
        case .staged:    return "STAGED"
        case .unstaged:  return "UNSTAGED"
        case .untracked: return "NEW"
        }
    }
}

/// Area-aware identity of a selected file. `area` is nil for commit review (a single tree); for
/// the working copy it disambiguates the same path appearing under both Staged and Unstaged.
struct DetailSelection: Hashable {
    var area: DetailArea?
    /// `DiffFile.id` for commits; the file's path for working-copy areas.
    var fileID: String
}

/// A titled group of analyzed files for the middle pane. A nil/empty title renders flat (no header).
struct DetailSection {
    var title: String?
    var area: DetailArea?
    var files: [FileAnalysis]
}

/// The model for the files-pane summary header.
enum DetailHeader {
    case none
    case commit(Commit?, note: CommitDetailPresenter.NoteState)
    case workingCopy(branch: String?, staged: Int, unstaged: Int, untracked: Int, prepared: String?)
}

// MARK: - Commit detail conformance

extension CommitDetailPresenter: DetailSource {
    var header: DetailHeader { .commit(commit, note: commitNote) }

    func sections(reviewMode: ReviewMode) -> [DetailSection] {
        FileOrganizer.organize(files, mode: reviewMode).map {
            DetailSection(title: $0.name, area: nil, files: $0.files)
        }
    }

    var selection: DetailSelection? {
        selectedFile.map { DetailSelection(area: nil, fileID: $0) }
    }

    func select(_ selection: DetailSelection?) { selectFile(selection?.fileID) }

    var selectedDiff: (file: DiffFile, areaBadge: String?)? {
        guard let id = selectedFile, let file = files.first(where: { $0.id == id }) else { return nil }
        return (file, nil)
    }

    var diffMode: Mode { mode }
    func setDiffMode(_ mode: Mode) { setMode(mode) }
}

// MARK: - Working-copy conformance

extension WorkingCopyPresenter: DetailSource {
    var header: DetailHeader {
        // staged/unstaged fall back to their parsed diff-file counts during a status reload so the
        // header stays stable. Untracked files aren't tracked in a separate diff state, so 0 is the
        // only option while loading — the count snaps to the real value once status resolves.
        .workingCopy(branch: status?.branch,
                     staged: status?.staged.count ?? stagedFiles.count,
                     unstaged: status?.unstaged.count ?? unstagedFiles.count,
                     untracked: status?.untracked.count ?? 0,
                     prepared: preparedMessage)
    }

    func sections(reviewMode: ReviewMode) -> [DetailSection] {
        var result: [DetailSection] = []
        if !stagedFiles.isEmpty {
            result.append(DetailSection(title: DetailArea.staged.sectionTitle, area: .staged,
                                        files: analyzed(stagedFiles)))
        }
        if !unstagedFiles.isEmpty {
            result.append(DetailSection(title: DetailArea.unstaged.sectionTitle, area: .unstaged,
                                        files: analyzed(unstagedFiles)))
        }
        let untracked = (status?.untracked ?? []).map(Self.untrackedDiffFile)
        if !untracked.isEmpty {
            result.append(DetailSection(title: DetailArea.untracked.sectionTitle, area: .untracked,
                                        files: analyzed(untracked)))
        }
        return result
    }

    var selection: DetailSelection? {
        guard let id = selectedFile, let area = Self.area(for: selectedArea) else { return nil }
        return DetailSelection(area: area, fileID: id)
    }

    func select(_ selection: DetailSelection?) {
        guard let selection, let area = selection.area else { selectFile(id: nil, area: nil); return }
        let range: DiffRange
        switch area {
        case .staged:    range = .workingStaged
        case .unstaged:  range = .workingUnstaged
        case .untracked: range = .workingUntracked(selection.fileID)
        }
        selectFile(id: selection.fileID, area: range)
    }

    var selectedDiff: (file: DiffFile, areaBadge: String?)? {
        guard let area = Self.area(for: selectedArea) else { return nil }
        // Untracked files have no tree diff until selected; synthesize the row from status so the
        // header still renders while contents load.
        if area == .untracked, selectedDiffFile == nil, let id = selectedFile {
            return (Self.untrackedDiffFile(FileStatus(path: id, status: .untracked)), area.badge)
        }
        guard let file = selectedDiffFile else { return nil }
        return (file, area.badge)
    }

    var diffMode: CommitDetailPresenter.Mode { mode }
    func setDiffMode(_ mode: CommitDetailPresenter.Mode) { setMode(mode) }

    var isLoading: Bool { isLoadingStatus || isLoadingDiff }
    var lastError: Error? { lastStatusError ?? lastDiffError }

    // MARK: helpers

    private func analyzed(_ files: [DiffFile]) -> [FileAnalysis] {
        files.map(FileAnalysis.analyze).sorted { a, b in
            if a.isNoise != b.isNoise { return !a.isNoise }   // substantive changes first
            return a.displayPath < b.displayPath
        }
    }

    /// An untracked file rendered as a new file: no hunks/stats until its contents are loaded.
    static func untrackedDiffFile(_ status: FileStatus) -> DiffFile {
        DiffFile(oldPath: nil, newPath: status.path, status: .untracked,
                 isBinary: false, hunks: [], additions: 0, deletions: 0)
    }

    static func area(for range: DiffRange?) -> DetailArea? {
        switch range {
        case .workingStaged:    return .staged
        case .workingUnstaged:  return .unstaged
        case .workingUntracked: return .untracked
        case .commit, .between, nil: return nil
        }
    }
}
