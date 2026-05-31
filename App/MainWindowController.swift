import AppKit

/// Owns the main window: a unified-toolbar window over a three-pane split
/// (Commit Timeline / Subsystem Files / Immersive Diff).
///
/// Per the UX brief, the window leans into native materials and a transparent titlebar
/// so content flows under the toolbar. Repositories are added by dropping a folder
/// anywhere on the window — they are contextual state, not a permanent navigation pane.
final class MainWindowController: NSWindowController {

    private let splitVC = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!

    private let timelineVC: TimelineViewController
    private let filesVC: NSViewController
    private let diffVC: NSViewController
    private let toolbarController: ToolbarController

    /// Called when the user drops one or more folders onto the window.
    var onDropFolders: (([URL]) -> Void)?

    // MARK: - Init

    init(toolbarController: ToolbarController,
         timelineVC: TimelineViewController,
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
        window.titleVisibility = .hidden
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
        let dropSplit = DropSplitView()
        dropSplit.isVertical = true
        dropSplit.onDropFolders = { [weak self] urls in self?.onDropFolders?(urls) }
        dropSplit.registerForDraggedTypes([.fileURL])
        dropSplit.autosaveName = "MainSplitView"
        splitVC.splitView = dropSplit

        sidebarItem = NSSplitViewItem(sidebarWithViewController: timelineVC)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 380
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.preferredThicknessFraction = 0.20

        let filesItem = NSSplitViewItem(viewController: filesVC)
        filesItem.minimumThickness = 240
        filesItem.preferredThicknessFraction = 0.22

        let diffItem = NSSplitViewItem(viewController: diffVC)
        diffItem.minimumThickness = 360

        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(filesItem)
        splitVC.addSplitViewItem(diffItem)

        window?.contentViewController = splitVC
    }

    // MARK: - Sidebar toggle

    func toggleTimeline() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            sidebarItem.animator().isCollapsed = !sidebarItem.isCollapsed
        }
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
