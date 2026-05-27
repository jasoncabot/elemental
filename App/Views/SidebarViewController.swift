import AppKit
import GitData

// MARK: - Sidebar item model (view-local, no GitData imports at the view level)

/// Opaque item the sidebar outline view displays. The view itself never inspects
/// git types — it gets display strings from the coordinator via this struct.
struct SidebarItem {
    enum Kind {
        case repoGroup(rootPath: String)
    }
    let id: URL         // stable identity (rootURL)
    let title: String
    let kind: Kind
}

// MARK: - Delegate protocol

@MainActor
protocol SidebarViewControllerDelegate: AnyObject {
    /// User dropped a folder URL onto the sidebar.
    func sidebarViewController(_ vc: SidebarViewController, didDropFolderAt url: URL)
    /// User dragged a repo row out of the sidebar.
    func sidebarViewController(_ vc: SidebarViewController, didRemoveRepoAt url: URL)
    /// User selected a repository row.
    func sidebarViewController(_ vc: SidebarViewController, didSelectRepo url: URL?)
}

// MARK: - View controller

/// Sidebar pane: an NSOutlineView listing dragged-in repositories.
/// Has zero git knowledge — it gets display items from the coordinator and
/// routes drag/selection actions back via its delegate.
final class SidebarViewController: NSViewController {
    weak var delegate: SidebarViewControllerDelegate?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

    /// Items set by the coordinator whenever `RepoBookmarkStore.repositories` changes.
    var items: [SidebarItem] = [] {
        didSet { outlineView.reloadData() }
    }

    // MARK: - Lifecycle

    override func loadView() {
        // Column
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repo"))
        col.title = "Repositories"
        col.resizingMask = .autoresizingMask
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.focusRingType = .none
        outlineView.dataSource = self
        outlineView.delegate = self

        // Drag-in: accept folder URLs from Finder/other apps
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.every, forLocal: false)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.reloadData()
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? items.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    // MARK: Drag source (drag-out to remove)

    func outlineView(_ outlineView: NSOutlineView,
                     pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let sidebarItem = item as? SidebarItem else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(sidebarItem.id.absoluteString, forType: .string)
        return pb
    }

    // MARK: Drag destination (drag-in from Finder)

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        // Only accept file-URL drops from outside the app
        guard info.draggingSource == nil ||
              (info.draggingSource as? NSOutlineView) !== outlineView else {
            return []
        }
        let pb = info.draggingPasteboard
        guard pb.canReadObject(forClasses: [NSURL.self],
                               options: [.urlReadingFileURLsOnly: true,
                                         .urlReadingContentsConformToTypes: ["public.folder"]]) else {
            return []
        }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: any NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        let pb = info.draggingPasteboard
        let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true,
                      .urlReadingContentsConformToTypes: ["public.folder"]]
        ) as? [URL] ?? []
        for url in urls {
            delegate?.sidebarViewController(self, didDropFolderAt: url)
        }
        return !urls.isEmpty
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }

        let id = NSUserInterfaceItemIdentifier("RepoCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = sidebarItem.title
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        if row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem {
            delegate?.sidebarViewController(self, didSelectRepo: item.id)
        } else {
            delegate?.sidebarViewController(self, didSelectRepo: nil)
        }
    }
}
