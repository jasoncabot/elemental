import AppKit

/// Owns the main window: a three-pane NSSplitView (sidebar / commit list / detail).
/// The coordinator builds and injects the child view controllers; this class is
/// responsible only for layout and window bookkeeping.
final class MainWindowController: NSWindowController, NSSplitViewDelegate {

    private let splitView = NSSplitView()

    private let sidebarVC: NSViewController
    private let commitListVC: NSViewController
    private let detailVC: NSViewController

    // MARK: - Init

    init(sidebarVC: NSViewController,
         commitListVC: NSViewController,
         detailVC: NSViewController) {
        self.sidebarVC = sidebarVC
        self.commitListVC = commitListVC
        self.detailVC = detailVC

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Elemental"
        window.center()
        window.setFrameAutosaveName("MainWindow")

        super.init(window: window)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Storyboards are not used") }

    // MARK: - Layout

    private func buildLayout() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.autoresizingMask = [.width, .height]

        // Add child views to split
        splitView.addArrangedSubview(sidebarVC.view)
        splitView.addArrangedSubview(commitListVC.view)
        splitView.addArrangedSubview(detailVC.view)

        window?.contentView = splitView

        // Hold child VCs so they aren't deallocated
        contentViewController = NSViewController()
        contentViewController?.addChild(sidebarVC)
        contentViewController?.addChild(commitListVC)
        contentViewController?.addChild(detailVC)
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        switch dividerIndex {
        case 0: return 160    // sidebar minimum
        case 1: return 400    // sidebar + commit list combined minimum
        default: return proposedMinimumPosition
        }
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        switch dividerIndex {
        case 0: return 320    // sidebar maximum
        default: return proposedMaximumPosition
        }
    }

    func splitView(_ splitView: NSSplitView,
                   resizeSubviewsWithOldSize oldSize: NSSize) {
        let total = splitView.bounds.width
        let dividerThickness = splitView.dividerThickness * 2

        let sidebarWidth = splitView.subviews[0].frame.width
        let remaining = total - sidebarWidth - dividerThickness
        let commitWidth = max(200, remaining * 0.4)
        let detailWidth = max(200, remaining - commitWidth)

        splitView.subviews[0].frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: splitView.bounds.height)
        splitView.subviews[1].frame = NSRect(x: sidebarWidth + splitView.dividerThickness,
                                              y: 0, width: commitWidth,
                                              height: splitView.bounds.height)
        splitView.subviews[2].frame = NSRect(x: sidebarWidth + splitView.dividerThickness + commitWidth + splitView.dividerThickness,
                                              y: 0, width: detailWidth,
                                              height: splitView.bounds.height)
    }
}
