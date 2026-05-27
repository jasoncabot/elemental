import Foundation
import GitData

/// Persists the set of repositories the user has dragged into the sidebar.
/// Uses plain bookmark data (no security scope — App Sandbox is off) saved to
/// `bookmarks.json` in Application Support. Validates each dropped folder is a
/// git repo via the backend before storing. Restores on launch; silently skips
/// entries that no longer resolve rather than crashing.
@MainActor
final class RepoBookmarkStore {
    private let backend: any GitBackend
    private let storeURL: URL

    /// Resolved repositories available to the UI. Order is preserved.
    private(set) var repositories: [Repository] = []

    /// Called whenever `repositories` changes so the coordinator can update the sidebar.
    var onRepositoriesChanged: (() -> Void)?

    init(backend: any GitBackend) {
        self.backend = backend
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Elemental", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("bookmarks.json")
    }

    // MARK: - Launch restoration

    /// Resolves saved bookmarks, opens each repo, and populates `repositories`.
    /// Missing/moved folders are skipped — never crashes.
    func restoreOnLaunch() async {
        let saved = loadBookmarks()
        var resolved: [Repository] = []
        for data in saved {
            guard let url = resolveBookmark(data) else { continue }
            if let repo = try? await backend.openRepository(at: url) {
                resolved.append(repo)
            }
        }
        repositories = resolved
        onRepositoriesChanged?()
    }

    // MARK: - Drag-in

    /// Validates that `url` is a git repository, then persists a bookmark and
    /// adds the repo to `repositories`. Returns the `Repository` on success.
    @discardableResult
    func add(url: URL) async throws -> Repository {
        // Validate it is actually a repository
        let repo = try await backend.openRepository(at: url)

        // Don't add duplicates
        guard !repositories.contains(where: { $0.rootURL == repo.rootURL }) else {
            return repo
        }

        // Persist bookmark
        var bookmarks = loadBookmarks()
        if let data = makeBookmark(for: url) {
            bookmarks.append(data)
            saveBookmarks(bookmarks)
        }

        repositories.append(repo)
        onRepositoriesChanged?()
        return repo
    }

    // MARK: - Drag-out

    /// Removes the repository from the list and drops its persisted bookmark.
    func remove(repo: Repository) {
        repositories.removeAll { $0.rootURL == repo.rootURL }
        // Rebuild bookmark list from the surviving URLs
        let surviving = repositories.compactMap { makeBookmark(for: $0.rootURL) }
        saveBookmarks(surviving)
        onRepositoriesChanged?()
    }

    // MARK: - Bookmark helpers

    private func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return url
    }

    private struct BookmarkFile: Codable {
        var bookmarks: [Data]
    }

    private func loadBookmarks() -> [Data] {
        guard let raw = try? Data(contentsOf: storeURL),
              let file = try? JSONDecoder().decode(BookmarkFile.self, from: raw)
        else { return [] }
        return file.bookmarks
    }

    private func saveBookmarks(_ bookmarks: [Data]) {
        let file = BookmarkFile(bookmarks: bookmarks)
        if let raw = try? JSONEncoder().encode(file) {
            try? raw.write(to: storeURL, options: .atomic)
        }
    }
}
