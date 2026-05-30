import AppKit

/// Owns the main window: a unified-toolbar window over a three-pane split
/// (Commit Timeline / Subsystem Files / Immersive Diff).
///
/// Per the UX brief, the window leans into native materials and a transparent titlebar
/// so content flows under the toolbar. Repositories are added by dropping a folder
/// anywhere on the window — they are contextual state, not a permanent navigation pane.
final class MainWindowController: NSWindowController, NSSplitViewDelegate {

    private let splitView = DropSplitView()

    private let timelineVC: NSViewController
    private let filesVC: NSViewController
    private let diffVC: NSViewController
    private let toolbarController: ToolbarController

    /// Called when the user drops one or more folders onto the window.
    var onDropFolders: (([URL]) -> Void)?

    // MARK: - Init

    init(toolbarController: ToolbarController,
         timelineVC: NSViewController,
         filesVC: NSViewController,
         diffVC: NSViewController) {
        self.toolbarController = toolbarController
        self.timelineVC = timelineVC
        self.filesVC = filesVC
        self.diffVC = diffVC

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Elemental"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = toolbarController.toolbar
        window.isRestorable = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        buildLayout()

        if !window.setFrameUsingName("MainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("MainWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Storyboards are not used") }

    // MARK: - Layout

    private func buildLayout() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false

        splitView.addArrangedSubview(timelineVC.view)
        splitView.addArrangedSubview(filesVC.view)
        splitView.addArrangedSubview(diffVC.view)

        splitView.onDropFolders = { [weak self] urls in self?.onDropFolders?(urls) }
        splitView.registerForDraggedTypes([.fileURL])

        window?.contentView = splitView

        // Initial proportions: narrow timeline (20%), medium files pane (22%), wide diff canvas (58%).
        DispatchQueue.main.async { [weak self] in
            guard let self, let width = self.window?.frame.width else { return }
            self.splitView.setPosition(width * 0.20, ofDividerAt: 0)
            self.splitView.setPosition(width * 0.42, ofDividerAt: 1)
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        switch dividerIndex {
        case 0: return 220
        case 1: return 460
        default: return proposedMinimumPosition
        }
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        switch dividerIndex {
        case 0: return 380
        case 1: return splitView.bounds.width - 360
        default: return proposedMaximumPosition
        }
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }
}

// MARK: - DropSplitView

/// Split view that accepts folder drops anywhere on the window to add repositories.
private final class DropSplitView: NSSplitView {
    var onDropFolders: (([URL]) -> Void)?

    private static let dropOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: ["public.folder"],
    ]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canRead(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: Self.dropOptions) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDropFolders?(urls)
        return true
    }

    private func canRead(_ sender: any NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: Self.dropOptions)
    }
}
