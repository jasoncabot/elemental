import AppKit

/// Lightweight repo descriptor for the toolbar popup (no git types at the view layer).
struct RepoChoice {
    let id: URL
    let title: String
}

@MainActor
protocol ToolbarControllerDelegate: AnyObject {
    func toolbarDidSelectRepo(_ url: URL)
    func toolbarDidChangeReviewMode(_ mode: ReviewMode)
    func toolbarDidChangeSearch(_ query: String)
}

/// Owns the window toolbar. The brief says the top bar carries *context, not content*:
/// repository selection, branch, review mode, and search live here so repositories never
/// permanently occupy a navigation pane.
@MainActor
final class ToolbarController: NSObject, NSToolbarDelegate {
    weak var delegate: ToolbarControllerDelegate?

    let toolbar = NSToolbar(identifier: "ElementalMainToolbar")

    private let repoPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let branchLabel = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl(
        labels: ReviewMode.allCases.map(\.title),
        trackingMode: .selectOne, target: nil, action: nil)
    private let searchField = NSSearchField()

    private var repos: [RepoChoice] = []

    private enum ItemID {
        static let repo = NSToolbarItem.Identifier("repo")
        static let branch = NSToolbarItem.Identifier("branch")
        static let mode = NSToolbarItem.Identifier("mode")
        static let search = NSToolbarItem.Identifier("search")
    }

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [ItemID.mode]

        repoPopup.target = self
        repoPopup.action = #selector(repoChanged)
        repoPopup.bezelStyle = .toolbar
        repoPopup.controlSize = .large

        branchLabel.font = Theme.Font.secondary
        branchLabel.textColor = .secondaryLabelColor
        branchLabel.lineBreakMode = .byTruncatingTail

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = ReviewMode.narrative.rawValue
        modeControl.controlSize = .large

        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.placeholderString = "Search files & commits"
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
    }

    // MARK: - Public API (coordinator-driven)

    func setRepos(_ repos: [RepoChoice], selected: URL?) {
        self.repos = repos
        repoPopup.removeAllItems()
        for repo in repos {
            repoPopup.addItem(withTitle: repo.title)
            repoPopup.lastItem?.image = NSImage(
                systemSymbolName: "folder", accessibilityDescription: nil)
            repoPopup.lastItem?.representedObject = repo.id
        }
        if repos.isEmpty {
            repoPopup.addItem(withTitle: "No Repository")
            repoPopup.isEnabled = false
        } else {
            repoPopup.isEnabled = true
            if let selected, let idx = repos.firstIndex(where: { $0.id == selected }) {
                repoPopup.selectItem(at: idx)
            }
        }
    }

    func setBranch(_ branch: String?) {
        branchLabel.stringValue = branch.map { "⎇ \($0)" } ?? ""
    }

    var reviewMode: ReviewMode {
        ReviewMode(rawValue: modeControl.selectedSegment) ?? .narrative
    }

    // MARK: - Actions

    @objc private func repoChanged() {
        guard let url = repoPopup.selectedItem?.representedObject as? URL else { return }
        delegate?.toolbarDidSelectRepo(url)
    }

    @objc private func modeChanged() {
        delegate?.toolbarDidChangeReviewMode(reviewMode)
    }

    @objc private func searchChanged() {
        delegate?.toolbarDidChangeSearch(searchField.stringValue)
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ItemID.repo:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = repoPopup
            item.label = "Repository"
            item.visibilityPriority = .high
            return item
        case ItemID.branch:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = branchLabel
            item.label = "Branch"
            return item
        case ItemID.mode:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = modeControl
            item.label = "Review Mode"
            item.visibilityPriority = .high
            return item
        case ItemID.search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField = searchField
            item.resignsFirstResponderWithCancel = true
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.repo, ItemID.branch, .flexibleSpace, ItemID.mode, .flexibleSpace, ItemID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace, .space]
    }
}
