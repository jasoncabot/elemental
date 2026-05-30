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

    private let repoButton: NSButton = {
        let b = NSButton(title: "No Repository", target: nil, action: nil)
        b.bezelStyle = .recessed
        b.controlSize = .regular
        b.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        b.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        b.image?.isTemplate = true
        b.imagePosition = .imageTrailing
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()
    private let repoMenu = NSMenu()
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

        repoButton.target = self
        repoButton.action = #selector(repoButtonClicked(_:))

        branchLabel.font = Theme.Font.secondary
        branchLabel.textColor = .secondaryLabelColor
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branchLabel.maximumNumberOfLines = 1
        branchLabel.preferredMaxLayoutWidth = 200
        // Size the toolbar item via a constraint (NSToolbarItem.min/maxSize are deprecated and
        // clip). A bare upper bound lets the label shrink to nothing when there's no branch and
        // cap+truncate at 200 when names are long.
        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        branchLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200)
            .id("ToolbarController.branchLabel.maxWidth")
            .isActive = true

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
        repoMenu.removeAllItems()
        if repos.isEmpty {
            repoButton.title = "No Repository"
            repoButton.isEnabled = false
        } else {
            repoButton.isEnabled = true
            for repo in repos {
                let item = NSMenuItem(title: repo.title, action: #selector(repoMenuItemSelected(_:)),
                                     keyEquivalent: "")
                item.target = self
                item.representedObject = repo.id
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                item.state = repo.id == selected ? .on : .off
                repoMenu.addItem(item)
            }
            let selectedTitle = repos.first(where: { $0.id == selected })?.title
                             ?? repos.first?.title
                             ?? "Repository"
            repoButton.title = selectedTitle
        }
    }

    func setBranch(_ branch: String?) {
        branchLabel.stringValue = branch.map { "⎇ \($0)" } ?? ""
        branchLabel.toolTip = branch
    }

    var reviewMode: ReviewMode {
        ReviewMode(rawValue: modeControl.selectedSegment) ?? .narrative
    }

    // MARK: - Actions

    @objc private func repoButtonClicked(_ sender: NSButton) {
        let location = NSPoint(x: 0, y: sender.bounds.height + 4)
        repoMenu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func repoMenuItemSelected(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
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
            item.view = repoButton
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
