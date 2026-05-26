import Foundation
import GitData

/// Loads and caches the diff for a selected commit. SHA is immutable, so cached diffs never go
/// stale and survive on-disk ref changes without refetching.
@MainActor
public final class CommitDetailPresenter: Presenter {
    public enum Mode: Sendable { case unified, sideBySide }

    private let backend: GitBackend
    private let repo: Repository

    public private(set) var sha: String?
    public private(set) var files: [DiffFile] = []
    public private(set) var selectedFile: DiffFile.ID?
    public private(set) var isLoading = false
    public private(set) var lastError: Error?
    public var mode: Mode = .unified

    private var cache: [String: [DiffFile]] = [:]
    private var loadTask: Task<Void, Never>?

    public init(backend: GitBackend, repo: Repository) {
        self.backend = backend
        self.repo = repo
        super.init()
    }

    public func show(sha: String?) {
        guard sha != self.sha else { return }
        self.sha = sha
        guard let sha else { files = []; selectedFile = nil; notify(); return }
        if let cached = cache[sha] {
            files = cached
            selectedFile = cached.first?.id
            notify()
            return
        }
        load(sha)
    }

    public func selectFile(_ id: DiffFile.ID?) {
        selectedFile = id
        notify()
    }

    private func load(_ sha: String) {
        loadTask?.cancel()
        isLoading = true
        lastError = nil
        notify()
        loadTask = Task { [weak self, backend, repo] in
            guard let self else { return }
            do {
                let result = try await backend.diff(.commit(sha), in: repo)
                if Task.isCancelled { return }
                self.cache[sha] = result
                guard self.sha == sha else { return }   // selection moved on while loading
                self.files = result
                self.selectedFile = result.first?.id
                self.isLoading = false
                self.notify()
            } catch is CancellationError {
                return
            } catch {
                guard self.sha == sha else { return }
                self.isLoading = false
                self.lastError = error
                self.notify()
            }
        }
    }

    deinit { loadTask?.cancel() }
}
