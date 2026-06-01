import AppKit
import GitData
import Presenters

@MainActor
protocol TimelineViewControllerDelegate: AnyObject {
    func timelineViewController(_ vc: TimelineViewController, didSelectSHA sha: String?)
    func timelineViewControllerDidSelectWorkingCopy(_ vc: TimelineViewController)
    func timelineViewControllerDidRequestRefresh(_ vc: TimelineViewController)
}

/// The left column: a readable review timeline rather than a git-log table.
///
/// Each commit reads like a message in a chat — an author glyph, the subject leading (wrapped to two
/// lines), then quiet recency/author metadata and ref pills. Commits with more to say carry a "more"
/// affordance that expands the row *in place* to reveal the full subject and body, so you can flick
/// through many commits collapsed and open just the ones you want. Collapsed rows are a fixed height
/// (no per-commit text measurement), which keeps the table virtualising large histories; only the
/// handful of expanded rows compute a height.
///
/// When a search is active the list switches to the presenter's bounded result set and a quiet strip
/// reports the match count.
final class TimelineViewController: NSViewController, PresenterObserving {
    weak var delegate: TimelineViewControllerDelegate?

    var presenter: TimelinePresenter? {
        didSet {
            oldValue?.removeObserver(self)
            presenter?.addObserver(self)
            expandedSHAs.removeAll()
            reloadFromPresenter()
        }
    }

    /// The working copy of the active repo, surfaced as a pinned, selectable row above the commits.
    /// Observed for live count/draft updates; nil when no repo is selected.
    var workingCopyPresenter: WorkingCopyPresenter? {
        didSet {
            guard workingCopyPresenter !== oldValue else { return }
            oldValue?.removeObserver(self)
            workingCopyPresenter?.addObserver(self)
            workingCopySelected = false
            pendingWorkingCopySelection = false
            refreshWorkingCopyRow()
        }
    }

    /// Selects the working copy row as soon as it first becomes visible.
    /// Has no effect if the row never appears (clean working copy).
    func selectWorkingCopyWhenAvailable() {
        pendingWorkingCopySelection = true
    }

    /// True while the user is reviewing the working copy rather than a commit.
    private(set) var workingCopySelected = false

    /// When true, the working copy row will be auto-selected the first time it becomes visible.
    private var pendingWorkingCopySelection = false

    private let tableView = TimelineTableView()
    private let scrollView = NSScrollView()
    private let dirtyBanner = DirtyBannerView()
    private let searchBanner = SearchBannerView()
    private let workingCopyRow = WorkingCopyRowView()
    private var workingCopyHeight: NSLayoutConstraint!
    /// A subtle downward shadow under the pinned working-copy row, so it reads as floating above
    /// the scrolling commit list. Visible only while the row itself is shown.
    private let workingCopyShadow = TopEdgeShadowView()
    private let emptyLabel = NSTextField(labelWithString: "Drop a repository folder here")
    private var isUpdatingSelection = false
    private var lastReportedSHA: String? = nil
    private var renderedRowCount = -1
    private var bannerHeight: NSLayoutConstraint!
    private var searchBannerHeight: NSLayoutConstraint!

    /// SHAs of commits the user has expanded in place. Persists across page eviction so an expanded
    /// commit re-opens when scrolled back into view.
    private var expandedSHAs: Set<String> = []
    /// Tracks the table width so expanded rows can be re-measured on resize.
    private var lastTableWidth: CGFloat = 0
    /// Tracks search on/off transitions so stale expansions are cleared when the list swaps.
    private var lastSearchActive = false

    // MARK: - Lifecycle

    override func loadView() {
        let col = NSTableColumn(identifier: .init("commit"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = Theme.Metric.timelineRowHeight
        tableView.focusRingType = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.selectionHighlightStyle = .regular
        // .plain (not .inset): the card's visual inset is drawn by the cell's cardLayer, and .inset
        // would additionally narrow the cell below tableView.bounds.width — breaking the expanded
        // row-height measurement (which measures against bounds.width) so text overflows the row.
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onNavigate = { [weak self] delta in self?.move(by: delta) }
        tableView.onContextMenu = { [weak self] row in self?.contextMenu(for: row) }

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = true

        dirtyBanner.refreshButton.target = self
        dirtyBanner.refreshButton.action = #selector(refreshTapped)
        dirtyBanner.isHidden = true

        searchBanner.isHidden = true

        workingCopyRow.onSelect = { [weak self] in self?.selectWorkingCopy() }
        workingCopyRow.isHidden = true

        emptyLabel.font = Theme.Font.secondary
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState

        dirtyBanner.translatesAutoresizingMaskIntoConstraints = false
        searchBanner.translatesAutoresizingMaskIntoConstraints = false
        workingCopyRow.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        workingCopyShadow.translatesAutoresizingMaskIntoConstraints = false
        workingCopyShadow.isHidden = true
        container.addSubview(scrollView)
        // Shadow sits above the scroll content but below the working-copy card.
        container.addSubview(workingCopyShadow)
        container.addSubview(dirtyBanner)
        container.addSubview(searchBanner)
        container.addSubview(workingCopyRow)
        container.addSubview(emptyLabel)

        bannerHeight = dirtyBanner.heightAnchor.constraint(equalToConstant: 0)
            .id("TimelineView.dirtyBanner.height")
        searchBannerHeight = searchBanner.heightAnchor.constraint(equalToConstant: 0)
            .id("TimelineView.searchBanner.height")
        workingCopyHeight = workingCopyRow.heightAnchor.constraint(equalToConstant: 0)
            .id("TimelineView.workingCopyRow.height")

        NSLayoutConstraint.activate([
            dirtyBanner.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor)
                .id("TimelineView.dirtyBanner.top"),
            dirtyBanner.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                .id("TimelineView.dirtyBanner.leading"),
            dirtyBanner.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                .id("TimelineView.dirtyBanner.trailing"),
            bannerHeight,

            searchBanner.topAnchor.constraint(equalTo: dirtyBanner.bottomAnchor)
                .id("TimelineView.searchBanner.top"),
            searchBanner.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                .id("TimelineView.searchBanner.leading"),
            searchBanner.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                .id("TimelineView.searchBanner.trailing"),
            searchBannerHeight,

            workingCopyRow.topAnchor.constraint(equalTo: searchBanner.bottomAnchor)
                .id("TimelineView.workingCopyRow.top"),
            workingCopyRow.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                .id("TimelineView.workingCopyRow.leading"),
            workingCopyRow.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                .id("TimelineView.workingCopyRow.trailing"),
            workingCopyHeight,

            scrollView.topAnchor.constraint(equalTo: workingCopyRow.bottomAnchor, constant: 6)
                .id("TimelineView.scrollView.top"),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                .id("TimelineView.scrollView.leading"),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                .id("TimelineView.scrollView.trailing"),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
                .id("TimelineView.scrollView.bottom"),

            workingCopyShadow.topAnchor.constraint(equalTo: workingCopyRow.bottomAnchor, constant: 6)
                .id("TimelineView.workingCopyShadow.top"),
            workingCopyShadow.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                .id("TimelineView.workingCopyShadow.leading"),
            workingCopyShadow.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                .id("TimelineView.workingCopyShadow.trailing"),
            workingCopyShadow.heightAnchor.constraint(equalToConstant: 6)
                .id("TimelineView.workingCopyShadow.height"),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor)
                .id("TimelineView.emptyLabel.centerX"),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                .id("TimelineView.emptyLabel.centerY"),
        ])

        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Expanded rows are measured against the table width; re-measure the visible ones on resize.
        let width = tableView.bounds.width
        guard width != lastTableWidth else { return }
        lastTableWidth = width
        guard !expandedSHAs.isEmpty else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        if visible.length > 0, let range = Range(visible) {
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: range))
        }
    }

    // MARK: - Actions

    @objc private func refreshTapped() {
        delegate?.timelineViewControllerDidRequestRefresh(self)
    }

    // MARK: - Expand / collapse

    private func toggleExpand(at row: Int) {
        guard let sha = presenter?.commit(atRow: row)?.sha else { return }
        if expandedSHAs.contains(sha) { expandedSHAs.remove(sha) } else { expandedSHAs.insert(sha) }
        // Update the row's content (body shown/hidden, chevron flipped) then animate its height.
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integer: 0))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
    }

    // MARK: - Context menu

    private func contextMenu(for row: Int) -> NSMenu? {
        guard let commit = presenter?.commit(atRow: row) else { return nil }

        let menu = NSMenu()

        let shortItem = NSMenuItem(title: "Copy SHA",
                                   action: #selector(copyShortSHA(_:)),
                                   keyEquivalent: "")
        shortItem.representedObject = commit
        shortItem.target = self
        menu.addItem(shortItem)

        let fullItem = NSMenuItem(title: "Copy Full SHA",
                                  action: #selector(copyFullSHA(_:)),
                                  keyEquivalent: "")
        fullItem.representedObject = commit
        fullItem.target = self
        menu.addItem(fullItem)

        menu.addItem(.separator())

        let msgItem = NSMenuItem(title: "Copy Commit Message",
                                 action: #selector(copyCommitMessage(_:)),
                                 keyEquivalent: "")
        msgItem.representedObject = commit
        msgItem.target = self
        menu.addItem(msgItem)

        return menu
    }

    @objc private func copyShortSHA(_ item: NSMenuItem) {
        guard let commit = item.representedObject as? Commit else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(commit.sha.prefix(7)), forType: .string)
    }

    @objc private func copyFullSHA(_ item: NSMenuItem) {
        guard let commit = item.representedObject as? Commit else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.sha, forType: .string)
    }

    @objc private func copyCommitMessage(_ item: NSMenuItem) {
        guard let commit = item.representedObject as? Commit else { return }
        let message = commit.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? commit.subject
            : "\(commit.subject)\n\n\(commit.body.trimmingCharacters(in: .whitespacesAndNewlines))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }

    private func move(by delta: Int) {
        guard let p = presenter, p.rowCount > 0 else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), p.rowCount - 1)
        guard next != current else { return }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: - PresenterObserving

    func presenterDidUpdate(_ presenter: AnyObject) {
        if presenter === workingCopyPresenter { refreshWorkingCopyRow() }
        else { reloadFromPresenter() }
    }

    // MARK: - Working-copy row

    private func selectWorkingCopy() {
        guard !workingCopyRow.isHidden else { return }
        workingCopySelected = true
        workingCopyRow.isSelected = true
        // Clear the commit selection without reporting it (we're switching to the working copy).
        isUpdatingSelection = true
        tableView.deselectAll(nil)
        isUpdatingSelection = false
        lastReportedSHA = nil
        delegate?.timelineViewControllerDidSelectWorkingCopy(self)
    }

    private func refreshWorkingCopyRow() {
        // The working copy isn't a commit and can't be a search hit — hide it while searching.
        if presenter?.isSearchActive == true {
            workingCopyRow.isHidden = true
            workingCopyShadow.isHidden = true
            workingCopyHeight.constant = 0
            return
        }
        guard let wc = workingCopyPresenter else {
            workingCopyRow.isHidden = true
            workingCopyShadow.isHidden = true
            workingCopyHeight.constant = 0
            if workingCopySelected {
                workingCopySelected = false
                workingCopyRow.isSelected = false
                lastReportedSHA = nil
                reloadFromPresenter()
            }
            return
        }
        // While status is reloading, leave the row exactly as it is — a transient nil status during
        // a refresh must not evict the user from working-copy review mode.
        guard !wc.isLoadingStatus else { return }
        guard let status = wc.status, !status.isClean else {
            workingCopyRow.isHidden = true
            workingCopyShadow.isHidden = true
            workingCopyHeight.constant = 0
            // The working copy went clean while it was being reviewed — fall back to the commit.
            if workingCopySelected {
                workingCopySelected = false
                workingCopyRow.isSelected = false
                lastReportedSHA = nil
                reloadFromPresenter()
            }
            return
        }
        workingCopyRow.isHidden = false
        workingCopyShadow.isHidden = false
        workingCopyHeight.constant = 64
        workingCopyRow.configure(staged: status.staged.count, unstaged: status.unstaged.count,
                                 untracked: status.untracked.count, conflicts: status.conflicts.count,
                                 draft: wc.preparedMessage)
        workingCopyRow.isSelected = workingCopySelected
        if pendingWorkingCopySelection {
            pendingWorkingCopySelection = false
            selectWorkingCopy()
        }
    }

    private func reloadFromPresenter() {
        let rowCount = presenter?.rowCount ?? 0
        let searching = presenter?.isSearchActive ?? false

        // A search session swap (or its end) invalidates expansions, whose heights no longer apply.
        if searching != lastSearchActive {
            lastSearchActive = searching
            expandedSHAs.removeAll()
        }

        // Quiet search strip ("12 results…" / "No commits match…").
        let summary = presenter?.searchSummary
        searchBanner.text = summary ?? ""
        searchBanner.isHidden = summary == nil
        searchBannerHeight.constant = summary == nil ? 0 : 30

        // The drop-target hint is for an empty pane only — never during a search (the strip speaks).
        emptyLabel.isHidden = rowCount > 0 || searching || (presenter?.totalCommitCount == nil)

        let dirty = presenter?.isDirty ?? false
        dirtyBanner.isHidden = !dirty
        bannerHeight.constant = dirty ? 30 : 0

        // Keep the working-copy row in step with search state.
        refreshWorkingCopyRow()

        // Structural change (row count moved) → tell the table; otherwise just refresh the
        // rows on screen so newly arrived pages render. Neither path moves the scroll position.
        if rowCount != renderedRowCount {
            renderedRowCount = rowCount
            tableView.reloadData()
        } else {
            let visible = tableView.rows(in: tableView.visibleRect)
            if visible.length > 0, let range = Range(visible) {
                tableView.reloadData(forRowIndexes: IndexSet(integersIn: range),
                                     columnIndexes: IndexSet(integer: 0))
            }
        }

        // While the working copy is being reviewed, leave the commit table unselected.
        guard !workingCopySelected else { return }

        let currentSHA = presenter?.selectedSHA
        if let sha = currentSHA, let rowIdx = presenter?.row(forSHA: sha),
           tableView.selectedRow != rowIdx {
            isUpdatingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: rowIdx), byExtendingSelection: false)
            isUpdatingSelection = false
        }

        if currentSHA != lastReportedSHA {
            lastReportedSHA = currentSHA
            delegate?.timelineViewController(self, didSelectSHA: currentSHA)
        }
    }

    private func commitSelected(sha: String) {
        if workingCopySelected {
            workingCopySelected = false
            workingCopyRow.isSelected = false
        }
        delegate?.timelineViewController(self, didSelectSHA: sha)
    }
}

// MARK: - Data / delegate

extension TimelineViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        presenter?.rowCount ?? 0
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TimelineRowView()
    }

    /// Collapsed rows are a constant height (no text measurement, so virtualisation is preserved);
    /// only expanded rows — a handful, always on-screen — compute their height from the content.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let collapsed = Theme.Metric.timelineRowHeight
        guard !expandedSHAs.isEmpty,
              let commit = presenter?.residentCommit(atRow: row),
              expandedSHAs.contains(commit.sha) else { return collapsed }
        return TimelineCellView.expandedHeight(for: commit, width: tableView.bounds.width)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // commit(atRow:) returns nil for a not-yet-resident page and schedules its load; the
        // presenter notifies on arrival and reloadFromPresenter refreshes the visible rows.
        guard let commit = presenter?.commit(atRow: row) else {
            let id = NSUserInterfaceItemIdentifier("TimelinePlaceholder")
            return tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
                ?? { let v = NSTableCellView(); v.identifier = id; return v }()
        }

        let id = NSUserInterfaceItemIdentifier("TimelineCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? TimelineCellView)
            ?? TimelineCellView(identifier: id)
        cell.configure(with: commit, expanded: expandedSHAs.contains(commit.sha))
        cell.onToggleExpand = { [weak self, weak cell] in
            guard let self, let cell else { return }
            let r = self.tableView.row(for: cell)
            guard r >= 0 else { return }
            self.toggleExpand(at: r)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection else { return }
        let row = tableView.selectedRow
        guard let sha = presenter?.commit(atRow: row)?.sha else { return }
        commitSelected(sha: sha)
    }
}

// MARK: - Timeline table (keyboard nav + context menu)

@objc(TimelineTableView)
private final class TimelineTableView: NSTableView {
    var onNavigate: ((Int) -> Void)?
    var onContextMenu: ((Int) -> NSMenu?)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "j": onNavigate?(1); return
        case "k": onNavigate?(-1); return
        case " ":
            // Space toggles expand on the selected commit cell if it has a "more" affordance.
            let row = selectedRow
            guard row >= 0 else { break }
            if let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? TimelineCellView {
                cell.toggleExpandIfPossible()
                return
            }
        default: break
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        // Select the right-clicked row so it's clear which commit the menu applies to.
        if selectedRow != row {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return onContextMenu?(row)
    }
}

// MARK: - Row view (gradient selection glow)

@objc(TimelineRowView)
private final class TimelineRowView: NSTableRowView {
    // Selection is rendered entirely by the cell's cardLayer so it is guaranteed to align
    // with the glass border. Suppress the row-level highlight completely.
    override func drawSelection(in dirtyRect: NSRect) {}

    // Drive the cell's selection styling from the row view rather than backgroundStyle: an
    // unfocused selected row reports backgroundStyle .normal (same as unselected), which would
    // make the selection vanish when focus moves to another pane. isSelected/isEmphasized stay
    // accurate regardless of which pane holds first responder.
    override var isSelected: Bool { didSet { propagateSelection() } }
    override var isEmphasized: Bool { didSet { propagateSelection() } }

    // Reused row/cell views may already hold the target selection state, so didSet won't fire —
    // apply the current state whenever a cell is (re)placed into this row.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let cell = subview as? TimelineCellView {
            cell.applySelectionState(selected: isSelected, emphasized: isEmphasized)
        }
    }

    private func propagateSelection() {
        for case let cell as TimelineCellView in subviews {
            cell.applySelectionState(selected: isSelected, emphasized: isEmphasized)
        }
    }
}

// MARK: - More control

// NSButton fights colours in selection contexts. NSImageView.contentTintColor is silently
// overridden to white by AppKit's emphasis pass even for template images. A single NSTextField
// with an NSAttributedString keeps text and chevron in one run so selection colour is always
// consistent. baselineOffset on the chevron portion corrects the optical misalignment that
// comes from the glyph's built-in descender.
private final class MoreControl: NSView {
    var action: (() -> Void)?

    private let label = NSTextField(labelWithString: "")

    var tintColor: NSColor = .tertiaryLabelColor {
        didSet { rebuildAttributedString() }
    }

    var title: String = "more " { didSet { rebuildAttributedString() } }

    /// Drives the chevron glyph: pass "chevron.up" or "chevron.down".
    var chevronName: String = "chevron.down" { didSet { rebuildAttributedString() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        rebuildAttributedString()
    }

    private func rebuildAttributedString() {
        let chevronGlyph = chevronName == "chevron.up" ? "⌃" : "⌄"
        let captionFont = Theme.Font.caption
        let chevronFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let color = tintColor

        let str = NSMutableAttributedString(string: title, attributes: [
            .font: captionFont,
            .foregroundColor: color,
        ])
        str.append(NSAttributedString(string: chevronGlyph, attributes: [
            .font: chevronFont,
            .foregroundColor: color,
            // Nudge the chevron glyph up to sit on the same optical line as the caption text.
            .baselineOffset: NSNumber(value: 1.5),
        ]))
        label.attributedStringValue = str
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { action?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
}

// MARK: - Cell view

/// A chat-style commit row. Collapsed it shows a two-line subject and a quiet metadata line with
/// ref pills and a faint SHA fingerprint. A coloured accent bar on the left edge signals the most
/// prominent ref (HEAD, tag, branch). When the commit has more to say, "more" expands the row in
/// place to reveal the full subject and body.
@objc(TimelineCellView)
private final class TimelineCellView: NSTableCellView {
    // Layout metrics (shared with `expandedHeight` so measurement matches the live layout).
    fileprivate static let textLeading: CGFloat = 20
    fileprivate static let trailing: CGFloat = 14
    fileprivate static let topInset: CGFloat = 13
    fileprivate static let bottomInset: CGFloat = 13
    fileprivate static let vSpacing: CGFloat = 6
    fileprivate static let metaRowHeight: CGFloat = 18

    var onToggleExpand: (() -> Void)?

    private let subjectLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let shaLabel = NSTextField(labelWithString: "")
    private let pillStack = NSStackView()
    private let moreButton = MoreControl()
    private let metaRow = NSStackView()
    private let vStack = NSStackView()

    // Glass card backing layer and left-edge accent bar.
    private let cardLayer = CALayer()
    private let accentBarLayer = CALayer()
    private var accentColor: NSColor?

    private var expanded = false

    // Selection state, set by the enclosing row view. `focused` means the timeline owns the
    // first responder in the key window (vivid accent); `selected` without `focused` is a quiet
    // accent border so the chosen commit stays obvious when another pane is active.
    private var rowSelected = false
    private var rowEmphasized = false

    func applySelectionState(selected: Bool, emphasized: Bool) {
        rowSelected = selected
        rowEmphasized = emphasized
        updateLayer()
        updateTextColors()
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        wantsLayer = true

        // Card layer sits behind all subviews and provides the frosted-glass card feel.
        cardLayer.cornerRadius = 10
        cardLayer.cornerCurve = .continuous
        cardLayer.borderWidth = 0.5
        layer?.addSublayer(cardLayer)

        // Thin rounded bar on the leading edge — coloured when a notable ref is present.
        accentBarLayer.cornerRadius = 1.5
        accentBarLayer.isHidden = true
        layer?.addSublayer(accentBarLayer)

        subjectLabel.font = Theme.Font.subject()
        subjectLabel.textColor = .labelColor
        subjectLabel.lineBreakMode = .byWordWrapping
        subjectLabel.maximumNumberOfLines = 2
        subjectLabel.cell?.usesSingleLineMode = false
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bodyLabel.font = Theme.Font.secondary
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.cell?.usesSingleLineMode = false
        bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metaLabel.font = Theme.Font.secondary
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Faint monospaced SHA fingerprint — a sophisticated detail at the far right of the meta row.
        shaLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        shaLabel.textColor = .quaternaryLabelColor
        shaLabel.lineBreakMode = .byTruncatingTail
        shaLabel.setContentHuggingPriority(.required, for: .horizontal)

        pillStack.orientation = .horizontal
        pillStack.spacing = 5
        pillStack.alignment = .centerY
        pillStack.setContentHuggingPriority(.required, for: .horizontal)

        moreButton.action = { [weak self] in self?.moreClicked() }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        metaRow.orientation = .horizontal
        metaRow.spacing = 6
        metaRow.alignment = .centerY
        metaRow.distribution = .fill
        metaRow.addArrangedSubview(pillStack)
        metaRow.addArrangedSubview(metaLabel)
        metaRow.addArrangedSubview(spacer)
        metaRow.addArrangedSubview(shaLabel)
        metaRow.addArrangedSubview(moreButton)

        vStack.orientation = .vertical
        vStack.alignment = .leading
        vStack.spacing = Self.vSpacing
        vStack.translatesAutoresizingMaskIntoConstraints = false
        vStack.addArrangedSubview(subjectLabel)
        vStack.addArrangedSubview(bodyLabel)
        vStack.addArrangedSubview(metaRow)

        addSubview(vStack)

        NSLayoutConstraint.activate([
            vStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textLeading)
                .id("TimelineCell.vStack.leading"),
            vStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailing)
                .id("TimelineCell.vStack.trailing"),
            vStack.topAnchor.constraint(equalTo: topAnchor, constant: Self.topInset)
                .id("TimelineCell.vStack.top"),
            // A `.leading`-aligned stack sizes children to their intrinsic width and won't stretch
            // them — so pin the wrapping labels and the meta row to the full text width, otherwise
            // the subject/body refuse to wrap and the "more" control floats mid-row.
            subjectLabel.widthAnchor.constraint(equalTo: vStack.widthAnchor)
                .id("TimelineCell.subject.width").h(),
            bodyLabel.widthAnchor.constraint(equalTo: vStack.widthAnchor)
                .id("TimelineCell.body.width").h(),
            metaRow.widthAnchor.constraint(equalTo: vStack.widthAnchor)
                .id("TimelineCell.metaRow.width").h(),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Called by the table when space is pressed on the selected row.
    func toggleExpandIfPossible() {
        guard !moreButton.isHidden else { return }
        onToggleExpand?()
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Floating card: 8pt horizontal inset gives clear breathing room from the sidebar edge.
        cardLayer.frame = CGRect(x: 8, y: 2, width: max(0, w - 16), height: max(0, h - 4))
        // Accent bar: 3pt wide, sits just inside the card's left edge.
        let barPad: CGFloat = 15
        let barH = max(0, h - barPad * 2)
        accentBarLayer.frame = CGRect(x: 13, y: barPad, width: 3, height: barH)
        CATransaction.commit()

        // Multiline labels need an explicit wrapping width to report the right height.
        let width = vStack.bounds.width
        if width > 0 {
            subjectLabel.preferredMaxLayoutWidth = width
            bodyLabel.preferredMaxLayoutWidth = width
        }
    }

    override func updateLayer() {
        super.updateLayer()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let focused = rowSelected && rowEmphasized
        let selected = rowSelected

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let accent = NSColor.controlAccentColor
        if focused {
            cardLayer.backgroundColor = dark
                ? accent.withAlphaComponent(0.14).cgColor
                : accent.withAlphaComponent(0.10).cgColor
            cardLayer.borderColor = dark
                ? accent.withAlphaComponent(0.70).cgColor
                : accent.withAlphaComponent(0.60).cgColor
        } else if selected {
            // Selected but another pane holds focus: keep a clearly visible accent border plus a
            // gentle accent fill so the chosen commit is unmistakable — just calmer than focused.
            cardLayer.backgroundColor = dark
                ? accent.withAlphaComponent(0.10).cgColor
                : accent.withAlphaComponent(0.07).cgColor
            cardLayer.borderColor = dark
                ? accent.withAlphaComponent(0.55).cgColor
                : accent.withAlphaComponent(0.50).cgColor
        } else if dark {
            cardLayer.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
            cardLayer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        } else {
            cardLayer.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
            cardLayer.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor
        }

        if let color = accentColor {
            accentBarLayer.backgroundColor = color.withAlphaComponent(dark ? 0.80 : 0.70).cgColor
        }

        CATransaction.commit()
    }

    // The card tint is subtle (10-14%) so the background stays near-white (light) or near-dark
    // (dark). Boost secondary/tertiary text to maintain contrast on that tinted surface.
    // The subject blends in a little accent colour so it reads as intentionally styled rather
    // than defaulting to stark white (dark) or plain black (light).
    private func updateTextColors() {
        let focused = rowSelected && rowEmphasized
        let appearance = effectiveAppearance
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        if focused {
            let label  = NSColor.labelColor.resolvedColor(for: appearance)
            let accent = NSColor.controlAccentColor.resolvedColor(for: appearance)
            let accentedLabel = label.blended(withFraction: 0.20, of: accent) ?? label

            subjectLabel.textColor = accentedLabel
            if dark {
                bodyLabel.textColor  = NSColor(white: 0.80, alpha: 1)
                metaLabel.textColor  = NSColor(white: 0.80, alpha: 1)
                shaLabel.textColor   = NSColor(white: 0.55, alpha: 1)
                applyMoreButtonColor(NSColor(white: 0.65, alpha: 1))
            } else {
                bodyLabel.textColor  = NSColor(white: 0.18, alpha: 1)
                metaLabel.textColor  = NSColor(white: 0.18, alpha: 1)
                shaLabel.textColor   = NSColor(white: 0.38, alpha: 1)
                applyMoreButtonColor(NSColor(white: 0.32, alpha: 1))
            }
        } else {
            subjectLabel.textColor = .labelColor
            bodyLabel.textColor    = .secondaryLabelColor
            metaLabel.textColor    = .secondaryLabelColor
            shaLabel.textColor     = .quaternaryLabelColor
            applyMoreButtonColor(.tertiaryLabelColor)
        }
    }

    private func applyMoreButtonColor(_ color: NSColor) {
        moreButton.tintColor = color
    }

    private func moreClicked() { onToggleExpand?() }

    func configure(with commit: Commit, expanded: Bool) {
        self.expanded = expanded
        let subject = commit.subject.isEmpty ? "(no subject)" : commit.subject
        subjectLabel.stringValue = subject
        subjectLabel.maximumNumberOfLines = expanded ? 0 : 2

        let mergeTag = commit.isMerge ? "merge · " : ""
        if expanded {
            metaLabel.stringValue = "\(mergeTag)\(RelativeDate.short(commit.authorDate)) · \(commit.author.name)"
        } else {
            metaLabel.stringValue = "\(mergeTag)\(RelativeDate.short(commit.authorDate))"
        }

        shaLabel.stringValue = String(commit.sha.prefix(7))

        toolTip = "\(commit.sha.prefix(10))\n\(commit.author.name) <\(commit.author.email)>\n\(RelativeDate.exact(commit.authorDate))"

        let body = commit.body.trimmingCharacters(in: .whitespacesAndNewlines)
        bodyLabel.stringValue = body
        bodyLabel.isHidden = !(expanded && !body.isEmpty)

        pillStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let pills = refPills(commit.refNames)
        for ref in pills.prefix(expanded ? 4 : 2) {
            pillStack.addArrangedSubview(BadgeLabel(text: ref.text, tint: ref.tint))
        }
        pillStack.isHidden = pillStack.arrangedSubviews.isEmpty

        // Accent bar: take the most prominent ref colour.
        accentColor = pills.first.map(\.tint)
        accentBarLayer.isHidden = accentColor == nil

        // "more" appears when there's a body or a subject that won't fit two collapsed lines.
        let canExpand = !body.isEmpty || subjectExceedsTwoLines(subject)
        moreButton.isHidden = !canExpand
        moreButton.title = expanded ? "less " : "more "
        moreButton.chevronName = expanded ? "chevron.up" : "chevron.down"

        updateLayer()
        updateTextColors()
        needsLayout = true
    }

    /// Cheap check for the collapsed "more" affordance: would the subject wrap past two lines at the
    /// current width? Falls back to a character-count heuristic before the cell has a width.
    private func subjectExceedsTwoLines(_ subject: String) -> Bool {
        let width = vStack.bounds.width
        guard width > 0 else { return subject.count > 80 }
        return Self.textHeight(subject, font: Theme.Font.subject(), width: width)
            > ceil(Theme.Font.subject().boundingRectForFont.height * 2) + 2
    }

    private func refPills(_ refNames: [String]) -> [(text: String, tint: NSColor)] {
        var pills: [(String, NSColor)] = []
        for raw in refNames {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            if name.contains("HEAD ->") {
                let branch = name.replacingOccurrences(of: "HEAD ->", with: "").trimmingCharacters(in: .whitespaces)
                pills.append((branch, .controlAccentColor))
            } else if name.hasPrefix("tag:") {
                pills.append((String(name.dropFirst(4)).trimmingCharacters(in: .whitespaces), .systemYellow))
            } else if name.hasPrefix("origin/") || name.contains("/") {
                pills.append((name, .systemGray))
            } else if name != "HEAD" {
                pills.append((name, .systemBlue))
            }
        }
        return pills
    }

    // MARK: - Height measurement

    /// Exact height for an expanded row, matching the live `vStack` layout above. Used by the
    /// table's `heightOfRow` only for the (few) expanded rows.
    static func expandedHeight(for commit: Commit, width tableWidth: CGFloat) -> CGFloat {
        let textWidth = max(40, tableWidth - textLeading - trailing)
        let subject = commit.subject.isEmpty ? "(no subject)" : commit.subject
        let subjectH = textHeight(subject, font: Theme.Font.subject(), width: textWidth)
        let body = commit.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyH = body.isEmpty ? 0 : textHeight(body, font: Theme.Font.secondary, width: textWidth)

        var height = topInset + subjectH + vSpacing + metaRowHeight + bottomInset
        if bodyH > 0 { height += bodyH + vSpacing }
        return ceil(max(height, Theme.Metric.timelineRowHeight))
    }

    // Shared label used only for height probing — never displayed.
    // NSTextFieldCell.cellSize(forBounds:) uses the same TextKit path as the live labels,
    // so it accounts for lineFragmentPadding and avoids the CoreText/TextKit split that
    // makes NSAttributedString.boundingRect diverge from what NSTextField actually renders.
    private static let measureLabel: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 0
        f.cell?.usesSingleLineMode = false
        return f
    }()

    private static func textHeight(_ string: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !string.isEmpty, width > 0 else { return 0 }
        measureLabel.font = font
        measureLabel.stringValue = string
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        return ceil(measureLabel.cell?.cellSize(forBounds: bounds).height ?? 0)
    }
}

// MARK: - Search strip

/// A thin downward-fading shadow used to lift the pinned working-copy row above the scrolling
/// commit list. Darkest at the top edge, fading to clear.
private final class TopEdgeShadowView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.colors = [NSColor.black.withAlphaComponent(0.16).cgColor, NSColor.clear.cgColor]
        // Layer space has y increasing upward, so the top edge is y = 1.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(gradient)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }
}

/// A quiet strip shown above the commit list while a search is active, reporting the match count
/// (or "no matches" / "showing first N"). Mirrors the dirty-banner pattern: calm, non-modal context.
@objc(SearchBannerView)
final class SearchBannerView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String = "" {
        didSet { label.stringValue = text; label.toolTip = text }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)

        label.font = Theme.Font.secondary
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        clipsToBounds = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
                .id("SearchBanner.stack.leading"),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
                .id("SearchBanner.stack.trailing"),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("SearchBanner.stack.centerY"),
        ])
    }
}

// MARK: - Dirty banner

/// Non-modal strip shown when git data changed on disk; never auto-reloads.
@objc(DirtyBannerView)
final class DirtyBannerView: NSView {
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.12).cgColor

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor

        let label = NSTextField(labelWithString: "Repository changed on disk")
        label.font = Theme.Font.secondary
        label.textColor = .secondaryLabelColor

        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.controlSize = .small
        refreshButton.font = Theme.Font.secondary

        let stack = NSStackView(views: [icon, label, refreshButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        clipsToBounds = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
                .id("DirtyBanner.stack.leading"),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("DirtyBanner.stack.centerY"),
        ])
    }
}

// MARK: - Working-copy row

/// The pinned, selectable entry above the commit list representing the *current* working copy —
/// the draft tip of the timeline. Shows staged/unstaged/untracked counts and any prepared commit
/// message. Selecting it routes the detail panes to working-copy review.
@objc(WorkingCopyRowView)
private final class WorkingCopyRowView: NSView {
    var onSelect: (() -> Void)?
    var isSelected = false {
        didSet {
            needsDisplay = true
            updateCardLayer()
        }
    }

    private let icon = NSImageView()
    private let iconCircleLayer = CALayer()
    private let titleLabel = NSTextField(labelWithString: "Uncommitted Changes")
    private let metaLabel = NSTextField(labelWithString: "")
    private let cardLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // Glass card layer (same treatment as commit cells).
        cardLayer.cornerRadius = 10
        cardLayer.cornerCurve = .continuous
        cardLayer.borderWidth = 0.5
        layer?.addSublayer(cardLayer)

        // Tinted circle behind the pencil icon.
        iconCircleLayer.cornerRadius = 12
        iconCircleLayer.cornerCurve = .continuous
        layer?.addSublayer(iconCircleLayer)

        icon.image = NSImage(systemSymbolName: "pencil.line", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)

        titleLabel.font = Theme.Font.subject()
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        metaLabel.font = Theme.Font.secondary
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon); addSubview(titleLabel); addSubview(metaLabel)
        // All horizontal constraints are .defaultHigh so the autoresizing-mask width==0
        // constraint (applied by NSSplitView at startup) can win without log spam.
        // Vertical anchors are required — they don't participate in the zero-width chain.
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22)
                .id("WorkingCopyRow.icon.leading").h(),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2)
                .id("WorkingCopyRow.icon.centerY"),
            icon.widthAnchor.constraint(equalToConstant: 16)
                .id("WorkingCopyRow.icon.width").h(),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10)
                .id("WorkingCopyRow.title.leading").h(),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14)
                .id("WorkingCopyRow.title.trailing").h(),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14)
                .id("WorkingCopyRow.title.top"),

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor)
                .id("WorkingCopyRow.meta.leading").h(),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
                .id("WorkingCopyRow.meta.trailing").h(),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3)
                .id("WorkingCopyRow.meta.top"),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.frame = CGRect(x: 8, y: 2, width: max(0, w - 16), height: max(0, h - 4))
        // Position the accent circle behind the icon, inside the card.
        iconCircleLayer.frame = CGRect(x: 14, y: (h - 24) / 2, width: 24, height: 24)
        CATransaction.commit()

        updateCardLayer()
    }

    override func updateLayer() {
        super.updateLayer()
        updateCardLayer()
    }

    private func updateCardLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let accent = NSColor.controlAccentColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        iconCircleLayer.backgroundColor = accent.withAlphaComponent(dark ? 0.18 : 0.13).cgColor

        if isSelected {
            cardLayer.backgroundColor = dark
                ? accent.withAlphaComponent(0.14).cgColor
                : accent.withAlphaComponent(0.10).cgColor
            cardLayer.borderColor = dark
                ? accent.withAlphaComponent(0.70).cgColor
                : accent.withAlphaComponent(0.60).cgColor
        } else if dark {
            cardLayer.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
            cardLayer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        } else {
            cardLayer.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
            cardLayer.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor
        }

        CATransaction.commit()

        if isSelected {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if dark {
                titleLabel.textColor = NSColor(white: 0.96, alpha: 1)
                metaLabel.textColor  = NSColor(white: 0.80, alpha: 1)
                icon.contentTintColor = NSColor(white: 0.90, alpha: 1)
            } else {
                titleLabel.textColor = .labelColor
                metaLabel.textColor  = NSColor(white: 0.18, alpha: 1)
                icon.contentTintColor = .controlAccentColor
            }
        } else {
            titleLabel.textColor = .labelColor
            metaLabel.textColor  = .secondaryLabelColor
            icon.contentTintColor = .controlAccentColor
        }
    }

    func configure(staged: Int, unstaged: Int, untracked: Int, conflicts: Int, draft: String?) {
        var parts: [String] = []
        if staged > 0 { parts.append("\(staged) staged") }
        if unstaged > 0 { parts.append("\(unstaged) unstaged") }
        if untracked > 0 { parts.append("\(untracked) untracked") }
        if conflicts > 0 { parts.append("\(conflicts) conflict\(conflicts == 1 ? "" : "s")") }
        let counts = parts.isEmpty ? "No changes" : parts.joined(separator: " · ")

        if let draft, case let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            let subject = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
            metaLabel.stringValue = "\(counts) \u{2014} \u{201C}\(subject)\u{201D}"
        } else {
            metaLabel.stringValue = counts
        }
        toolTip = metaLabel.stringValue
        setAccessibilityLabel("Uncommitted changes: \(metaLabel.stringValue)")
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    // Selection is rendered entirely by updateCardLayer via the cardLayer, so draw() is unused.
}
