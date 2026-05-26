import AppKit
import GitData
import Presenters

/// The main window: a three-pane split (sidebar / commit list / detail). Phase A wires the shell
/// and proves the data layer links and runs; the rich views land in the view-layer feature.
final class MainWindowController: NSWindowController {
    private let backend: GitBackend?
    private let statusLabel = NSTextField(labelWithString: "Elemental")

    init() {
        self.backend = try? CLIGitBackend()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Elemental"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)
        buildLayout()
        loadGitVersion()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Storyboards are not used") }

    private func buildLayout() {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        split.addArrangedSubview(makePane("Repositories", background: .controlBackgroundColor))
        split.addArrangedSubview(makePane("Commits", background: .textBackgroundColor))

        let detail = makePane("Detail", background: .textBackgroundColor)
        detail.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 16),
            statusLabel.topAnchor.constraint(equalTo: detail.topAnchor, constant: 16),
        ])
        split.addArrangedSubview(detail)

        window?.contentView = split
    }

    private func makePane(_ title: String, background: NSColor) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = background.cgColor
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        return view
    }

    private func loadGitVersion() {
        guard let backend else {
            statusLabel.stringValue = "git not found on PATH"
            return
        }
        Task { @MainActor in
            if let version = try? await backend.gitVersion() {
                statusLabel.stringValue = "Connected to \(version)"
            } else {
                statusLabel.stringValue = "git not available"
            }
        }
    }
}
