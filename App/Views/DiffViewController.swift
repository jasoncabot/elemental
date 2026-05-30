import AppKit
import GitData
import Presenters

/// The right column: the core reading experience. The brief asks for a calm,
/// typography-led canvas — not a patch stream. We give the diff generous spacing,
/// soft add/remove tints, a clear file header, collapsible hunks, and automatic
/// collapse of low-signal noise (lockfiles, generated files) that stays one click away.
///
/// Each hunk has its own horizontal scroll view so long lines in one hunk don't
/// force every other hunk off-screen.
/// One content row within a single hunk — no header rows, those are separate views.
private enum HunkRow {
    case line(DiffLine)
    case pair(left: DiffLine?, right: DiffLine?)
}

final class DiffViewController: NSViewController, PresenterObserving {

    var source: (any DetailSource)? {
        didSet {
            oldValue?.removeObserver(self)
            source?.addObserver(self)
            reload()
        }
    }

    /// Per-side gutter width and the centre divider width used by the side-by-side cell.
    fileprivate static let sideGutter: CGFloat = 40
    fileprivate static let sideDivider: CGFloat = 1

    private let header = DiffHeaderView()
    private let outerScroll = NSScrollView()
    // NSScrollView positions non-flipped document views at the bottom of the clip view
    // when the content is shorter than the viewport. A flipped view pins content to the top.
    private let outerContent = FlippedView()
    private let emptyLabel = NSTextField(labelWithString: "Select a commit to read its changes")

    private var hunkSections: [HunkSectionView] = []
    /// Shown in place of hunk sections for noise-collapsed or binary files.
    private var noticeView: NSView?
    /// Maps each inner NSTableView → its HunkSectionView for data source lookups.
    private var tableToSection: [NSTableView: HunkSectionView] = [:]
    /// The stacking constraints that pin sections top-to-bottom inside outerContent.
    /// Deactivated and replaced on every rebuild to avoid duplicates.
    private var sectionStackConstraints: [NSLayoutConstraint] = []

    private var currentSelection: DetailSelection?
    private var currentFile: DiffFile?
    private var sideBySide = false
    private var collapsedHunks: Set<Int> = []
    private var noiseExpanded = false
    private var focusChanges = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeDidChange),
                                               name: .diffFontSizeDidChange, object: nil)
    }

    @objc private func fontSizeDidChange() { reload() }

    override func loadView() {
        outerContent.translatesAutoresizingMaskIntoConstraints = false

        outerScroll.documentView = outerContent
        outerScroll.drawsBackground = false
        outerScroll.hasVerticalScroller = true
        outerScroll.hasHorizontalScroller = false
        outerScroll.autohidesScrollers = true
        outerScroll.borderType = .noBorder

        // outerContent fills the scroll view's width; height is determined by its subviews.
        NSLayoutConstraint.activate([
            outerContent.leadingAnchor.constraint(equalTo: outerScroll.contentView.leadingAnchor)
                .id("DiffView.outerContent.leading"),
            outerContent.trailingAnchor.constraint(equalTo: outerScroll.contentView.trailingAnchor)
                .id("DiffView.outerContent.trailing"),
            outerContent.topAnchor.constraint(equalTo: outerScroll.contentView.topAnchor)
                .id("DiffView.outerContent.top"),
        ])

        header.onExpandNoise = { [weak self] in
            self?.noiseExpanded = true
            self?.rebuildHunks()
        }
        header.onToggleFocus = { [weak self] in
            guard let self else { return }
            self.focusChanges.toggle()
            self.rebuildHunks()
        }
        header.onToggleMode = { [weak self] in
            guard let self else { return }
            self.source?.setDiffMode(self.sideBySide ? .unified : .sideBySide)
        }

        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        outerScroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        container.addSubview(outerScroll)
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor)
                .id("DiffView.header.top"),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                .id("DiffView.header.leading"),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                .id("DiffView.header.trailing"),

            outerScroll.topAnchor.constraint(equalTo: header.bottomAnchor)
                .id("DiffView.outerScroll.top"),
            outerScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                .id("DiffView.outerScroll.leading"),
            outerScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                .id("DiffView.outerScroll.trailing"),
            outerScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
                .id("DiffView.outerScroll.bottom"),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor)
                .id("DiffView.emptyLabel.centerX"),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                .id("DiffView.emptyLabel.centerY"),
        ])

        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateAllContentColumnWidths()
    }

    // MARK: - PresenterObserving

    func presenterDidUpdate(_ presenter: AnyObject) { reload() }

    private func reload() {
        let selectedDiff = source?.selectedDiff
        let file = selectedDiff?.file

        let hasContent = file != nil
        emptyLabel.isHidden = hasContent
        header.isHidden = !hasContent
        outerScroll.isHidden = !hasContent

        let selection = source?.selection
        if selection != currentSelection {
            currentSelection = selection
            collapsedHunks = []
            noiseExpanded = false
        }
        sideBySide = source?.diffMode == .sideBySide

        guard let file else {
            currentFile = nil
            clearSections()
            return
        }
        currentFile = file
        let analysis = FileAnalysis.analyze(file)
        header.configure(with: analysis, areaBadge: selectedDiff?.areaBadge)
        header.setMode(sideBySide)
        rebuildHunks(analysis: analysis)
    }

    private func rebuildHunks(analysis passedAnalysis: FileAnalysis? = nil) {
        guard let file = currentFile else { clearSections(); return }
        let analysis = passedAnalysis ?? FileAnalysis.analyze(file)

        if analysis.isNoise && !noiseExpanded {
            let label = analysis.signals.first(where: {
                $0 == .lockfile || $0 == .generated || $0 == .dependency
            })?.label ?? "noise"
            header.setNoiseCollapsed(true)
            header.setFocus(focusChanges, churnLines: 0)
            showNotice(signal: label, lines: file.additions + file.deletions)
            return
        }
        header.setNoiseCollapsed(false)

        if file.hunks.isEmpty && file.isBinary {
            showNotice(signal: "binary", lines: 0)
            return
        }

        let churnLines = file.hunks.reduce(0) { sum, hunk in
            sum + hunk.lines.filter { $0.kind != .context && $0.change != .substantive }.count
        }
        header.setFocus(focusChanges, churnLines: churnLines)

        // Remove notice if present.
        noticeView?.removeFromSuperview()
        noticeView = nil

        // Build rows per hunk.
        var newSections: [HunkSectionView] = []
        for (i, hunk) in file.hunks.enumerated() {
            let visible = focusChanges
                ? hunk.lines.filter { $0.kind == .context || $0.change == .substantive }
                : hunk.lines
            let rows: [HunkRow] = sideBySide
                ? Self.pair(visible).map { .pair(left: $0, right: $1) }
                : visible.map { .line($0) }

            let contentMinWidth = computeContentMinWidth(rows)
            let section = reuseOrMake(index: i,
                                      text: hunk.context ?? hunk.header,
                                      rows: rows,
                                      contentMinWidth: contentMinWidth)
            section.isCollapsed = collapsedHunks.contains(i)
            section.configureSideBySide(sideBySide)
            newSections.append(section)
        }

        installSections(newSections)
        updateAllContentColumnWidths()
    }

    // MARK: - Section management

    private func clearSections() {
        hunkSections.forEach { $0.removeFromSuperview() }
        hunkSections = []
        tableToSection = [:]
        noticeView?.removeFromSuperview()
        noticeView = nil
    }

    private func showNotice(signal: String, lines: Int) {
        clearSections()
        let tf = NSTextField(labelWithString: lines > 0
            ? "Collapsed \(signal) — \(lines) changed line\(lines == 1 ? "" : "s"). Use \u{201C}Show anyway\u{201D} above."
            : "Binary file — no textual diff.")
        tf.font = Theme.Font.secondary
        tf.textColor = .secondaryLabelColor
        tf.translatesAutoresizingMaskIntoConstraints = false
        outerContent.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: outerContent.leadingAnchor, constant: 12)
                .id("DiffView.notice.leading"),
            tf.topAnchor.constraint(equalTo: outerContent.topAnchor, constant: 12)
                .id("DiffView.notice.top"),
            tf.bottomAnchor.constraint(equalTo: outerContent.bottomAnchor, constant: -12)
                .id("DiffView.notice.bottom"),
        ])
        noticeView = tf
    }

    private func reuseOrMake(index: Int, text: String, rows: [HunkRow],
                             contentMinWidth: CGFloat) -> HunkSectionView {
        let section: HunkSectionView
        if let existing = hunkSections.first(where: { $0.hunkIndex == index }) {
            section = existing
        } else {
            section = HunkSectionView(hunkIndex: index, dataSource: self, delegate: self)
            section.onToggle = { [weak self] in self?.toggleHunk(index) }
            tableToSection[section.innerTable] = section
        }
        section.rows = rows
        section.contentMinWidth = contentMinWidth
        section.headerText = text
        section.reloadTable()
        return section
    }

    private func installSections(_ sections: [HunkSectionView]) {
        // Drop sections that are no longer needed.
        let removed = Set(hunkSections).subtracting(sections)
        removed.forEach {
            $0.removeFromSuperview()
            tableToSection.removeValue(forKey: $0.innerTable)
        }
        hunkSections = sections

        // Always rebuild the vertical stacking chain from scratch to avoid duplicates.
        NSLayoutConstraint.deactivate(sectionStackConstraints)
        sectionStackConstraints = []

        var prev: NSView? = nil
        for section in sections {
            if section.superview == nil {
                section.translatesAutoresizingMaskIntoConstraints = false
                outerContent.addSubview(section)
                // Leading/trailing are fixed per section — add once.
                NSLayoutConstraint.activate([
                    section.leadingAnchor.constraint(equalTo: outerContent.leadingAnchor)
                        .id("hunkSection[\(section.hunkIndex)].leading"),
                    section.trailingAnchor.constraint(equalTo: outerContent.trailingAnchor)
                        .id("hunkSection[\(section.hunkIndex)].trailing"),
                ])
            }
            // Vertical chain — rebuilt every call.
            let top = prev.map { section.topAnchor.constraint(equalTo: $0.bottomAnchor)
                                    .id("hunkSection[\(section.hunkIndex)].top") }
                       ?? section.topAnchor.constraint(equalTo: outerContent.topAnchor)
                            .id("hunkSection[\(section.hunkIndex)].top")
            sectionStackConstraints.append(top)
            prev = section
        }
        let bottom = sections.last
            .map { $0.bottomAnchor.constraint(equalTo: outerContent.bottomAnchor)
                        .id("hunkSection[\($0.hunkIndex)].bottom") }
            ?? outerContent.heightAnchor.constraint(equalToConstant: 0)
                    .id("hunkStack.emptyHeight")
        sectionStackConstraints.append(bottom)
        NSLayoutConstraint.activate(sectionStackConstraints)
    }

    // MARK: - Column width

    private func updateAllContentColumnWidths() {
        let available = max(outerScroll.bounds.width, 100)
        for section in hunkSections {
            section.updateContentColumnWidth(available: available)
        }
    }

    // MARK: - Hunk toggle

    private func toggleHunk(_ index: Int) {
        if collapsedHunks.contains(index) { collapsedHunks.remove(index) }
        else { collapsedHunks.insert(index) }
        if let section = hunkSections.first(where: { $0.hunkIndex == index }) {
            section.isCollapsed = collapsedHunks.contains(index)
        }
    }

    // MARK: - Row building helpers

    private func computeContentMinWidth(_ rows: [HunkRow]) -> CGFloat {
        let charWidth = Theme.Font.code().maximumAdvancement.width
        func w(_ text: String) -> CGFloat { CGFloat(text.count + 2) * charWidth + 24 }
        return rows.reduce(CGFloat(0)) { best, row in
            switch row {
            case .line(let l): return max(best, w(l.text))
            case .pair(let l, let r):
                let per = max(l.map { w($0.text) } ?? 0, r.map { w($0.text) } ?? 0)
                return max(best, per * 2 + Self.sideGutter * 2 + Self.sideDivider)
            }
        }
    }

    private static func pair(_ lines: [DiffLine]) -> [(DiffLine?, DiffLine?)] {
        var result: [(DiffLine?, DiffLine?)] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []
        func flush() {
            let n = max(removed.count, added.count)
            for i in 0..<n {
                result.append((i < removed.count ? removed[i] : nil,
                               i < added.count ? added[i] : nil))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }
        for line in lines {
            switch line.kind {
            case .context: flush(); result.append((line, line))
            case .removed: removed.append(line)
            case .added:   added.append(line)
            }
        }
        flush()
        return result
    }
}

// MARK: - Per-hunk section view

private final class HunkSectionView: NSView {
    let hunkIndex: Int
    var rows: [HunkRow] = []
    var contentMinWidth: CGFloat = 0
    var onToggle: (() -> Void)?

    var headerText: String = "" {
        didSet { headerLabel.stringValue = (isCollapsed ? "▸ " : "▾ ") + headerText }
    }
    var isCollapsed: Bool = false {
        didSet {
            headerLabel.stringValue = (isCollapsed ? "▸ " : "▾ ") + headerText
            innerScroll.isHidden = isCollapsed
            innerHeightConstraint.constant = isCollapsed ? 0 : rowsHeight
        }
    }

    private(set) var innerTable: NSTableView
    let innerScroll: HorizontalScrollView
    private let headerLabel: NSTextField
    private let headerBg: NSView
    private let innerContentCol: NSTableColumn
    private var innerHeightConstraint: NSLayoutConstraint!

    private var rowsHeight: CGFloat {
        CGFloat(rows.count) * Theme.Metric.diffLineHeight
    }

    init(hunkIndex: Int, dataSource: NSTableViewDataSource, delegate: NSTableViewDelegate) {
        self.hunkIndex = hunkIndex

        headerLabel = NSTextField(labelWithString: "")
        headerLabel.font = Theme.Font.codeMeta
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        headerBg = NSView()
        headerBg.wantsLayer = true
        headerBg.translatesAutoresizingMaskIntoConstraints = false

        let oldCol = NSTableColumn(identifier: .init("old"))
        oldCol.width = 46; oldCol.minWidth = 46; oldCol.maxWidth = 46; oldCol.resizingMask = []
        let newCol = NSTableColumn(identifier: .init("new"))
        newCol.width = 46; newCol.minWidth = 46; newCol.maxWidth = 46; newCol.resizingMask = []
        innerContentCol = NSTableColumn(identifier: .init("content"))
        innerContentCol.resizingMask = []

        let tbl = NSTableView()
        tbl.addTableColumn(oldCol)
        tbl.addTableColumn(newCol)
        tbl.addTableColumn(innerContentCol)
        tbl.columnAutoresizingStyle = .noColumnAutoresizing
        tbl.headerView = nil
        tbl.backgroundColor = .clear
        tbl.rowHeight = Theme.Metric.diffLineHeight
        tbl.focusRingType = .none
        tbl.intercellSpacing = .zero
        tbl.gridStyleMask = []
        tbl.selectionHighlightStyle = .none
        tbl.dataSource = dataSource
        tbl.delegate = delegate
        innerTable = tbl

        innerScroll = HorizontalScrollView()
        innerScroll.documentView = tbl
        innerScroll.drawsBackground = false
        innerScroll.hasHorizontalScroller = true
        innerScroll.hasVerticalScroller = false
        innerScroll.autohidesScrollers = true
        innerScroll.borderType = .noBorder
        innerScroll.horizontalScrollElasticity = .none
        innerScroll.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        addSubview(headerBg)
        headerBg.addSubview(headerLabel)
        addSubview(innerScroll)

        innerHeightConstraint = innerScroll.heightAnchor.constraint(equalToConstant: 0)
            .id("HunkSection.innerScroll.height")
        NSLayoutConstraint.activate([
            headerBg.topAnchor.constraint(equalTo: topAnchor)
                .id("HunkSection.headerBg.top"),
            headerBg.leadingAnchor.constraint(equalTo: leadingAnchor)
                .id("HunkSection.headerBg.leading"),
            headerBg.trailingAnchor.constraint(equalTo: trailingAnchor)
                .id("HunkSection.headerBg.trailing"),
            headerBg.heightAnchor.constraint(equalToConstant: Theme.Metric.hunkHeaderHeight)
                .id("HunkSection.headerBg.height"),

            headerLabel.leadingAnchor.constraint(equalTo: headerBg.leadingAnchor, constant: 8)
                .id("HunkSection.headerLabel.leading"),
            headerLabel.trailingAnchor.constraint(equalTo: headerBg.trailingAnchor, constant: -8)
                .id("HunkSection.headerLabel.trailing"),
            headerLabel.centerYAnchor.constraint(equalTo: headerBg.centerYAnchor)
                .id("HunkSection.headerLabel.centerY"),

            innerScroll.topAnchor.constraint(equalTo: headerBg.bottomAnchor)
                .id("HunkSection.innerScroll.top"),
            innerScroll.leadingAnchor.constraint(equalTo: leadingAnchor)
                .id("HunkSection.innerScroll.leading"),
            innerScroll.trailingAnchor.constraint(equalTo: trailingAnchor)
                .id("HunkSection.innerScroll.trailing"),
            innerScroll.bottomAnchor.constraint(equalTo: bottomAnchor)
                .id("HunkSection.innerScroll.bottom"),
            innerHeightConstraint,
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(headerTapped))
        headerBg.addGestureRecognizer(click)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        headerBg.layer?.backgroundColor = Theme.Color.hunkBackground.cgColor
    }

    @objc private func headerTapped() { onToggle?() }

    func reloadTable() {
        innerTable.rowHeight = Theme.Metric.diffLineHeight
        innerHeightConstraint.constant = isCollapsed ? 0 : rowsHeight
        innerTable.reloadData()
    }

    func updateContentColumnWidth(available: CGFloat) {
        // Gutter columns are hidden in side-by-side mode; subtract only the visible ones.
        let gutterCols = innerTable.tableColumns.filter { $0.identifier.rawValue != "content" }
        let gutterWidth = gutterCols.reduce(0) { $0 + ($1.isHidden ? 0 : $1.width) }
        let target = max(available - gutterWidth, contentMinWidth, 100)
        guard abs(innerContentCol.width - target) > 0.5 else { return }
        innerContentCol.width = target
    }

    func configureSideBySide(_ sideBySide: Bool) {
        for col in innerTable.tableColumns where col.identifier.rawValue != "content" {
            col.isHidden = sideBySide
        }
    }
}


// MARK: - Table data source / delegate

extension DiffViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableToSection[tableView]?.rows.count ?? 0
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Theme.Metric.diffLineHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard let section = tableToSection[tableView],
              row >= 0, row < section.rows.count else { return DiffRowView() }
        let rv = DiffRowView()
        switch section.rows[row] {
        case .line(let l):
            if l.change != .substantive { rv.fill = .clear }
            else {
                switch l.kind {
                case .added:   rv.fill = Theme.Color.addedBackground
                case .removed: rv.fill = Theme.Color.removedBackground
                case .context: rv.fill = .clear
                }
            }
        case .pair:
            rv.fill = .clear
        }
        return rv
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let section = tableToSection[tableView],
              row >= 0, row < section.rows.count else { return nil }
        let colID = tableColumn?.identifier.rawValue ?? ""
        switch section.rows[row] {
        case .line(let line):
            switch colID {
            case "old": return gutterCell(in: tableView, text: line.oldLineNumber.map(String.init) ?? "")
            case "new": return gutterCell(in: tableView, text: line.newLineNumber.map(String.init) ?? "")
            default:    return contentCell(in: tableView, line: line)
            }
        case .pair(let left, let right):
            guard colID == "content" else { return gutterCell(in: tableView, text: "") }
            return splitCell(in: tableView, left: left, right: right)
        }
    }
}

// MARK: - Cell builders

extension DiffViewController {
    private func contentCell(in table: NSTableView, line: DiffLine) -> NSView {
        let id = NSUserInterfaceItemIdentifier("content")
        let cell = dequeue(id, in: table) {
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byClipping
            tf.translatesAutoresizingMaskIntoConstraints = false
            $0.addSubview(tf); $0.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: $0.leadingAnchor, constant: 8)
                    .id("DiffContentCell.text.leading"),
                tf.trailingAnchor.constraint(equalTo: $0.trailingAnchor)
                    .id("DiffContentCell.text.trailing"),
                tf.centerYAnchor.constraint(equalTo: $0.centerYAnchor)
                    .id("DiffContentCell.text.centerY"),
            ])
        }
        cell.textField?.font = Theme.Font.code()
        let marker: String
        switch line.kind {
        case .added:   marker = "+"; cell.textField?.textColor = Theme.Color.addedText
        case .removed: marker = "−"; cell.textField?.textColor = Theme.Color.removedText
        case .context: marker = " "; cell.textField?.textColor = .labelColor
        }
        switch line.change {
        case .substantive: cell.toolTip = nil
        case .whitespace:
            cell.textField?.textColor = .tertiaryLabelColor
            cell.toolTip = "Whitespace-only change"
        case .moved:
            cell.textField?.textColor = .tertiaryLabelColor
            cell.toolTip = "Moved code — appears elsewhere in this diff"
        }
        cell.textField?.stringValue = marker + " " + line.text
        return cell
    }

    private func gutterCell(in table: NSTableView, text: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("gutter")
        let cell = dequeue(id, in: table) {
            let tf = NSTextField(labelWithString: "")
            tf.alignment = .right
            tf.textColor = .tertiaryLabelColor
            tf.translatesAutoresizingMaskIntoConstraints = false
            $0.addSubview(tf); $0.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: $0.leadingAnchor)
                    .id("DiffGutterCell.text.leading"),
                tf.trailingAnchor.constraint(equalTo: $0.trailingAnchor, constant: -6)
                    .id("DiffGutterCell.text.trailing"),
                tf.centerYAnchor.constraint(equalTo: $0.centerYAnchor)
                    .id("DiffGutterCell.text.centerY"),
            ])
        }
        cell.textField?.font = Theme.Font.codeGutter
        cell.textField?.stringValue = text
        return cell
    }

    private func splitCell(in table: NSTableView, left: DiffLine?, right: DiffLine?) -> NSView {
        let id = NSUserInterfaceItemIdentifier("split")
        let cell = (table.makeView(withIdentifier: id, owner: self) as? SplitCellView)
            ?? SplitCellView(identifier: id)
        cell.configure(left: left, right: right)
        return cell
    }

    private func dequeue(_ id: NSUserInterfaceItemIdentifier, in table: NSTableView,
                         make: (NSTableCellView) -> Void) -> NSTableCellView {
        if let reused = table.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            return reused
        }
        let cell = NSTableCellView(); cell.identifier = id; make(cell); return cell
    }
}

// MARK: - Side-by-side toggle (updates all hunk tables)

extension DiffViewController {
    // Called from reload() when sideBySide changes — rebuildHunks handles everything.
}

// MARK: - Flipped document view

/// NSScrollView places non-flipped document views at the bottom of the visible area when
/// the content is shorter than the viewport. Flipping the document view pins it to the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Horizontal-only scroll view

/// A scroll view that only handles horizontal scroll events, passing vertical ones up the
/// responder chain to the outer scroll view. Without this, each inner hunk scroll view
/// rubber-bands vertically on a trackpad, stealing events and making the outer scroll jerky.
private final class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

// MARK: - Row background

private final class DiffRowView: NSTableRowView {
    var fill: NSColor = .clear
    override func drawBackground(in dirtyRect: NSRect) { fill.setFill(); dirtyRect.fill() }
}

// MARK: - Side-by-side line cell

private final class SplitCellView: NSTableCellView {
    private let leftBG = NSView()
    private let rightBG = NSView()
    private let leftGutter = NSTextField(labelWithString: "")
    private let rightGutter = NSTextField(labelWithString: "")
    private let leftText = NSTextField(labelWithString: "")
    private let rightText = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        for bg in [leftBG, rightBG] {
            bg.wantsLayer = true; bg.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bg)
        }
        for g in [leftGutter, rightGutter] {
            g.alignment = .right; g.textColor = .tertiaryLabelColor
            g.translatesAutoresizingMaskIntoConstraints = false
        }
        for t in [leftText, rightText] {
            t.lineBreakMode = .byClipping; t.translatesAutoresizingMaskIntoConstraints = false
        }
        [leftGutter, leftText, rightGutter, rightText].forEach(addSubview)

        let g = DiffViewController.sideGutter
        NSLayoutConstraint.activate([
            leftBG.leadingAnchor.constraint(equalTo: leadingAnchor)
                .id("SplitCell.leftBG.leading"),
            leftBG.topAnchor.constraint(equalTo: topAnchor)
                .id("SplitCell.leftBG.top"),
            leftBG.bottomAnchor.constraint(equalTo: bottomAnchor)
                .id("SplitCell.leftBG.bottom"),
            leftBG.trailingAnchor.constraint(equalTo: centerXAnchor)
                .id("SplitCell.leftBG.trailing"),
            rightBG.leadingAnchor.constraint(equalTo: centerXAnchor)
                .id("SplitCell.rightBG.leading"),
            rightBG.topAnchor.constraint(equalTo: topAnchor)
                .id("SplitCell.rightBG.top"),
            rightBG.bottomAnchor.constraint(equalTo: bottomAnchor)
                .id("SplitCell.rightBG.bottom"),
            rightBG.trailingAnchor.constraint(equalTo: trailingAnchor)
                .id("SplitCell.rightBG.trailing"),

            leftGutter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
                .id("SplitCell.leftGutter.leading"),
            leftGutter.widthAnchor.constraint(equalToConstant: g - 6)
                .id("SplitCell.leftGutter.width"),
            leftGutter.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("SplitCell.leftGutter.centerY"),
            leftText.leadingAnchor.constraint(equalTo: leftGutter.trailingAnchor, constant: 4)
                .id("SplitCell.leftText.leading"),
            leftText.trailingAnchor.constraint(lessThanOrEqualTo: centerXAnchor, constant: -4)
                .id("SplitCell.leftText.trailing"),
            leftText.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("SplitCell.leftText.centerY"),

            rightGutter.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 6)
                .id("SplitCell.rightGutter.leading"),
            rightGutter.widthAnchor.constraint(equalToConstant: g - 6)
                .id("SplitCell.rightGutter.width"),
            rightGutter.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("SplitCell.rightGutter.centerY"),
            rightText.leadingAnchor.constraint(equalTo: rightGutter.trailingAnchor, constant: 4)
                .id("SplitCell.rightText.leading"),
            rightText.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
                .id("SplitCell.rightText.trailing"),
            rightText.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("SplitCell.rightText.centerY"),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(left: DiffLine?, right: DiffLine?) {
        let gutterFont = Theme.Font.codeGutter
        let codeFont = Theme.Font.code()
        for g in [leftGutter, rightGutter] { g.font = gutterFont }
        for t in [leftText, rightText] { t.font = codeFont }
        configureSide(gutter: leftGutter, text: leftText, line: left, isOld: true)
        configureSide(gutter: rightGutter, text: rightText, line: right, isOld: false)
        leftBG.layer?.backgroundColor = Self.background(for: left).cgColor
        rightBG.layer?.backgroundColor = Self.background(for: right).cgColor
    }

    private func configureSide(gutter: NSTextField, text: NSTextField,
                                line: DiffLine?, isOld: Bool) {
        guard let line else { gutter.stringValue = ""; text.stringValue = ""; return }
        gutter.stringValue = (isOld ? line.oldLineNumber : line.newLineNumber).map(String.init) ?? ""
        let marker: String
        switch line.kind {
        case .added:   marker = "+"; text.textColor = Theme.Color.addedText
        case .removed: marker = "−"; text.textColor = Theme.Color.removedText
        case .context: marker = " "; text.textColor = .labelColor
        }
        if line.change != .substantive {
            text.textColor = .tertiaryLabelColor
            text.toolTip = line.change == .whitespace ? "Whitespace-only change"
                                                      : "Moved code — appears elsewhere in this diff"
        } else { text.toolTip = nil }
        text.stringValue = marker + " " + line.text
    }

    private static func background(for line: DiffLine?) -> NSColor {
        guard let line, line.change == .substantive else { return .clear }
        switch line.kind {
        case .added:   return Theme.Color.addedBackground
        case .removed: return Theme.Color.removedBackground
        case .context: return .clear
        }
    }
}

// MARK: - File header

private final class DiffHeaderView: NSView {
    private let icon = NSImageView()
    private let areaBadgeStack = NSStackView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let statLabel = NSTextField(labelWithString: "")
    private let signalStack = NSStackView()
    private let showButton = NSButton(title: "Show anyway", target: nil, action: nil)
    private let focusButton = NSButton(title: "Focus", target: nil, action: nil)
    private let modeButton = NSButton(title: "", target: nil, action: nil)
    private let divider = NSBox()

    var onExpandNoise: (() -> Void)?
    var onToggleFocus: (() -> Void)?
    var onToggleMode: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)

        pathLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statLabel.font = Theme.Font.secondary
        statLabel.translatesAutoresizingMaskIntoConstraints = false

        signalStack.orientation = .horizontal
        signalStack.spacing = 4
        signalStack.translatesAutoresizingMaskIntoConstraints = false

        showButton.bezelStyle = .accessoryBarAction
        showButton.controlSize = .small
        showButton.font = Theme.Font.secondary
        showButton.target = self; showButton.action = #selector(expandTapped)
        showButton.isHidden = true
        showButton.translatesAutoresizingMaskIntoConstraints = false

        focusButton.bezelStyle = .accessoryBarAction
        focusButton.controlSize = .small
        focusButton.font = Theme.Font.secondary
        focusButton.setButtonType(.pushOnPushOff)
        focusButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle",
                                    accessibilityDescription: "Focus changes")
        focusButton.imagePosition = .imageLeading
        focusButton.target = self; focusButton.action = #selector(focusTapped)
        focusButton.isHidden = true
        focusButton.toolTip = "Hide whitespace-only and moved lines"
        focusButton.translatesAutoresizingMaskIntoConstraints = false

        modeButton.bezelStyle = .accessoryBarAction
        modeButton.controlSize = .small
        modeButton.setButtonType(.pushOnPushOff)
        modeButton.imagePosition = .imageOnly
        modeButton.target = self; modeButton.action = #selector(modeTapped)
        modeButton.toolTip = "Side-by-side view"
        modeButton.translatesAutoresizingMaskIntoConstraints = false

        areaBadgeStack.orientation = .horizontal
        areaBadgeStack.translatesAutoresizingMaskIntoConstraints = false
        areaBadgeStack.isHidden = true

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, areaBadgeStack, pathLabel, signalStack,
                                      showButton, focusButton, modeButton, statLabel])
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setCustomSpacing(10, after: pathLabel)
        addSubview(row); addSubview(divider)

        let rowTrailing = row.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                        constant: -Theme.Metric.pad)
            .id("DiffHeader.row.trailing")
        rowTrailing.priority = .defaultHigh
        clipsToBounds = true
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metric.pad)
                .id("DiffHeader.row.leading"),
            rowTrailing,
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8)
                .id("DiffHeader.row.top"),
            row.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -8)
                .id("DiffHeader.row.bottom"),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor)
                .id("DiffHeader.divider.leading"),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor)
                .id("DiffHeader.divider.trailing"),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor)
                .id("DiffHeader.divider.bottom"),
            heightAnchor.constraint(equalToConstant: 44)
                .id("DiffHeader.height"),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func expandTapped() { onExpandNoise?() }
    @objc private func focusTapped() { onToggleFocus?() }
    @objc private func modeTapped() { onToggleMode?() }

    func setFocus(_ on: Bool, churnLines: Int) {
        focusButton.isHidden = churnLines == 0
        focusButton.state = on ? .on : .off
        focusButton.title = on ? "\(churnLines) hidden" : "Focus"
    }

    func setMode(_ sideBySide: Bool) {
        modeButton.state = sideBySide ? .on : .off
        modeButton.image = NSImage(
            systemSymbolName: sideBySide ? "rectangle" : "rectangle.split.2x1",
            accessibilityDescription: sideBySide ? "Unified view" : "Side-by-side view")
        modeButton.toolTip = sideBySide ? "Switch to unified view" : "Switch to side-by-side view"
    }

    func configure(with fa: FileAnalysis, areaBadge: String?) {
        let tint = Theme.Color.statusColor(fa.statusKind)
        icon.image = NSImage(systemSymbolName: fa.iconName, accessibilityDescription: nil)
        icon.contentTintColor = tint

        areaBadgeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let areaBadge {
            let badgeTint: NSColor
            switch areaBadge {
            case "STAGED":   badgeTint = .systemGreen
            case "UNSTAGED": badgeTint = .systemOrange
            default:         badgeTint = .systemBlue
            }
            areaBadgeStack.addArrangedSubview(
                BadgeLabel(text: areaBadge, tint: badgeTint, font: Theme.Font.caption))
        }
        areaBadgeStack.isHidden = areaBadge == nil
        pathLabel.stringValue = fa.displayPath

        let stat = NSMutableAttributedString()
        if fa.file.additions > 0 {
            stat.append(NSAttributedString(string: "+\(fa.file.additions)  ",
                attributes: [.foregroundColor: Theme.Color.addStat, .font: Theme.Font.secondary]))
        }
        if fa.file.deletions > 0 {
            stat.append(NSAttributedString(string: "−\(fa.file.deletions)",
                attributes: [.foregroundColor: Theme.Color.delStat, .font: Theme.Font.secondary]))
        }
        statLabel.attributedStringValue = stat

        signalStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for signal in fa.signals.prefix(3) {
            signalStack.addArrangedSubview(
                BadgeLabel(text: signal.label, tint: signal.tint, font: Theme.Font.caption))
        }
    }

    func setNoiseCollapsed(_ collapsed: Bool) { showButton.isHidden = !collapsed }
}
