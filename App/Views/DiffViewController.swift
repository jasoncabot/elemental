import AppKit
import GitData
import Presenters

/// The right column: the core reading experience. The brief asks for a calm,
/// typography-led canvas — not a patch stream. We give the diff generous spacing,
/// soft add/remove tints, a clear file header, collapsible hunks, and automatic
/// collapse of low-signal noise (lockfiles, generated files) that stays one click away.
final class DiffViewController: NSViewController, PresenterObserving {

    var source: (any DetailSource)? {
        didSet {
            oldValue?.removeObserver(self)
            source?.addObserver(self)
            reload()
        }
    }

    private enum Row {
        case hunkHeader(index: Int, text: String)
        case line(DiffLine)
        /// One visual row of a side-by-side diff: old line on the left, new line on the right.
        case pair(left: DiffLine?, right: DiffLine?)
        case collapsedNotice(signal: String, lines: Int)
    }

    /// Per-side gutter width and the centre divider width used by the side-by-side cell.
    fileprivate static let sideGutter: CGFloat = 40
    fileprivate static let sideDivider: CGFloat = 1

    private let header = DiffHeaderView()
    private let table = DiffTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Select a commit to read its changes")
    private let contentCol = NSTableColumn(identifier: .init("content"))

    private var rows: [Row] = []
    private var contentColumnMinWidth: CGFloat = 0
    private var currentSelection: DetailSelection?
    private var currentFile: DiffFile?
    private var sideBySide = false
    private var collapsedHunks: Set<Int> = []
    private var noiseExpanded = false
    /// When on, whitespace-only and moved lines are hidden so only substantive edits remain.
    /// Persists across file selection — a reviewing preference, not per-file state.
    private var focusChanges = false

    // MARK: - Lifecycle

    override func loadView() {
        let oldCol = gutterColumn("old")
        let newCol = gutterColumn("new")
        contentCol.resizingMask = []
        table.addTableColumn(oldCol)
        table.addTableColumn(newCol)
        table.addTableColumn(contentCol)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Theme.Metric.diffLineHeight
        table.focusRingType = .none
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.onToggleHunk = { [weak self] index in self?.toggleHunk(index) }
        table.hunkIndexProvider = { [weak self] row in
            guard let self, row >= 0, row < self.rows.count else { return nil }
            if case .hunkHeader(let index, _) = self.rows[row] { return index }
            return nil
        }

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        header.onExpandNoise = { [weak self] in
            self?.noiseExpanded = true
            self?.rebuildRows()
        }

        header.onToggleFocus = { [weak self] in
            guard let self else { return }
            self.focusChanges.toggle()
            self.rebuildRows()
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
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        container.addSubview(scroll)
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateContentColumnWidth()
    }

    private func updateContentColumnWidth() {
        // The unified gutters live in their own columns; side-by-side hides them and carries its
        // gutters inside the content column, so the content takes the full width there.
        let gutterWidth: CGFloat = sideBySide ? 0 : (46 + 46)
        let available = max(scroll.bounds.width - gutterWidth, 100)
        let target = max(available, contentColumnMinWidth)
        guard abs(contentCol.width - target) > 0.5 else { return }
        contentCol.width = target
    }

    private func gutterColumn(_ id: String) -> NSTableColumn {
        let col = NSTableColumn(identifier: .init(id))
        col.width = 46; col.minWidth = 46; col.maxWidth = 46
        col.resizingMask = []
        return col
    }

    // MARK: - PresenterObserving

    func presenterDidUpdate(_ presenter: AnyObject) { reload() }

    private func reload() {
        let selectedDiff = source?.selectedDiff
        let file = selectedDiff?.file

        let hasContent = file != nil
        emptyLabel.isHidden = hasContent
        header.isHidden = !hasContent
        scroll.isHidden = !hasContent

        let selection = source?.selection
        if selection != currentSelection {
            currentSelection = selection
            collapsedHunks = []
            noiseExpanded = false
        }
        sideBySide = source?.diffMode == .sideBySide

        guard let file else { currentFile = nil; rows = []; table.reloadData(); return }
        currentFile = file
        let analysis = FileAnalysis.analyze(file)
        header.configure(with: analysis, areaBadge: selectedDiff?.areaBadge)
        header.setMode(sideBySide)
        rebuildRows(analysis: analysis)
    }

    private func rebuildRows(analysis passedAnalysis: FileAnalysis? = nil) {
        guard let file = currentFile else {
            rows = []; table.reloadData(); return
        }
        let analysis = passedAnalysis ?? FileAnalysis.analyze(file)

        // Auto-collapse low-signal noise until the user opts in.
        if analysis.isNoise && !noiseExpanded {
            let label = analysis.signals.first(where: { $0 == .lockfile || $0 == .generated || $0 == .dependency })?.label ?? "noise"
            rows = [.collapsedNotice(signal: label, lines: file.additions + file.deletions)]
            header.setNoiseCollapsed(true)
            header.setFocus(focusChanges, churnLines: 0)   // no per-line focus while whole file is collapsed
            table.reloadData()
            return
        }
        header.setNoiseCollapsed(false)

        // Count churn (whitespace/moved) so the header can offer to hide it.
        let churnLines = file.hunks.reduce(0) { sum, hunk in
            sum + hunk.lines.filter { $0.kind != .context && $0.change != .substantive }.count
        }
        header.setFocus(focusChanges, churnLines: churnLines)

        var built: [Row] = []
        for (i, hunk) in file.hunks.enumerated() {
            // Prefer git's clean function/section context; fall back to the raw @@ range header.
            built.append(.hunkHeader(index: i, text: hunk.context ?? hunk.header))
            if !collapsedHunks.contains(i) {
                // In focus mode, drop churn lines entirely (context always stays).
                let visible = focusChanges
                    ? hunk.lines.filter { $0.kind == .context || $0.change == .substantive }
                    : hunk.lines
                if sideBySide {
                    for (l, r) in Self.pair(visible) { built.append(.pair(left: l, right: r)) }
                } else {
                    for line in visible { built.append(.line(line)) }
                }
            }
        }
        if file.hunks.isEmpty && file.isBinary {
            built = [.collapsedNotice(signal: "binary", lines: 0)]
        }
        rows = built
        configureColumns()
        let charWidth = Theme.Font.code().maximumAdvancement.width
        func width(_ text: String) -> CGFloat { CGFloat(text.count + 2) * charWidth + 24 }
        contentColumnMinWidth = rows.reduce(CGFloat(0)) { best, row in
            switch row {
            case .line(let l):
                return max(best, width(l.text))
            case .pair(let l, let r):
                // Side-by-side holds both halves in the content column, so it needs room for two.
                let per = max(l.map { width($0.text) } ?? 0, r.map { width($0.text) } ?? 0)
                return max(best, per * 2 + Self.sideGutter * 2 + Self.sideDivider)
            default:
                return best
            }
        }
        updateContentColumnWidth()
        table.reloadData()
        if !rows.isEmpty { table.scrollRowToVisible(0) }
    }

    /// Pair a hunk's lines for side-by-side: removed lines fill the left column, added the right,
    /// and a context line flushes any pending pair then shows identically on both sides.
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

    /// Show the two gutter columns only in unified mode; side-by-side carries its own gutters
    /// inside the full-width content column.
    private func configureColumns() {
        for col in table.tableColumns where col.identifier.rawValue != "content" {
            col.isHidden = sideBySide
        }
    }

    private func toggleHunk(_ index: Int) {
        if collapsedHunks.contains(index) { collapsedHunks.remove(index) }
        else { collapsedHunks.insert(index) }
        rebuildRows()
    }
}

// MARK: - Table data / delegate

extension DiffViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < rows.count else { return Theme.Metric.diffLineHeight }
        switch rows[row] {
        case .hunkHeader: return Theme.Metric.hunkHeaderHeight
        case .collapsedNotice: return 44
        case .line, .pair: return Theme.Metric.diffLineHeight
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = DiffRowView()
        guard row >= 0, row < rows.count else { return rv }
        switch rows[row] {
        case .hunkHeader:
            rv.fill = Theme.Color.hunkBackground
        case .collapsedNotice, .pair:
            // Side-by-side rows tint each half independently inside the cell, so the row stays clear.
            rv.fill = .clear
        case .line(let l):
            // Churn (whitespace/moved) recedes: drop the add/remove wash so substantive edits pop.
            if l.change != .substantive {
                rv.fill = .clear
            } else {
                switch l.kind {
                case .added:   rv.fill = Theme.Color.addedBackground
                case .removed: rv.fill = Theme.Color.removedBackground
                case .context: rv.fill = .clear
                }
            }
        }
        return rv
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count else { return nil }
        let colID = tableColumn?.identifier.rawValue ?? ""
        switch rows[row] {
        case .hunkHeader(let index, let text):
            if colID == "old" && !sideBySide {
                return chevronCell(collapsed: collapsedHunks.contains(index))
            }
            if colID != "content" { return gutterCell("") }
            return hunkHeaderCell(text, collapsed: sideBySide ? collapsedHunks.contains(index) : nil)
        case .collapsedNotice(let signal, let lines):
            if colID != "content" { return gutterCell("") }
            return noticeCell(signal: signal, lines: lines)
        case .line(let line):
            switch colID {
            case "old": return gutterCell(line.oldLineNumber.map(String.init) ?? "")
            case "new": return gutterCell(line.newLineNumber.map(String.init) ?? "")
            default:    return contentCell(line)
            }
        case .pair(let left, let right):
            guard colID == "content" else { return gutterCell("") }
            return splitCell(left: left, right: right)
        }
    }

    // MARK: - Cell builders

    private func contentCell(_ line: DiffLine) -> NSView {
        let id = NSUserInterfaceItemIdentifier("content")
        let cell = dequeue(id) {
            let tf = NSTextField(labelWithString: "")
            tf.font = Theme.Font.code()
            tf.lineBreakMode = .byClipping
            tf.translatesAutoresizingMaskIntoConstraints = false
            $0.addSubview(tf); $0.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: $0.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: $0.trailingAnchor),
                tf.centerYAnchor.constraint(equalTo: $0.centerYAnchor),
            ])
        }
        let marker: String
        switch line.kind {
        case .added:   marker = "+"; cell.textField?.textColor = Theme.Color.addedText
        case .removed: marker = "−"; cell.textField?.textColor = Theme.Color.removedText
        case .context: marker = " "; cell.textField?.textColor = .labelColor
        }
        // Churn recedes to a muted tone and explains itself on hover.
        switch line.change {
        case .substantive:
            cell.toolTip = nil
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

    private func gutterCell(_ text: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("gutter")
        let cell = dequeue(id) {
            let tf = NSTextField(labelWithString: "")
            tf.alignment = .right
            tf.font = Theme.Font.codeGutter
            tf.textColor = .tertiaryLabelColor
            tf.translatesAutoresizingMaskIntoConstraints = false
            $0.addSubview(tf); $0.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: $0.leadingAnchor),
                tf.trailingAnchor.constraint(equalTo: $0.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: $0.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = text
        return cell
    }

    private func chevronCell(collapsed: Bool) -> NSView {
        let id = NSUserInterfaceItemIdentifier("chevron")
        let cell = dequeue(id) {
            let iv = NSImageView()
            iv.contentTintColor = .tertiaryLabelColor
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleNone
            $0.addSubview(iv)
            $0.imageView = iv
            NSLayoutConstraint.activate([
                iv.trailingAnchor.constraint(equalTo: $0.trailingAnchor, constant: -6),
                iv.centerYAnchor.constraint(equalTo: $0.centerYAnchor),
            ])
        }
        cell.imageView?.image = NSImage(
            systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: nil)
        return cell
    }

    private func hunkHeaderCell(_ text: String, collapsed: Bool? = nil) -> NSView {
        let id = NSUserInterfaceItemIdentifier("hunk")
        let cell = dequeue(id) {
            let tf = NSTextField(labelWithString: "")
            tf.font = Theme.Font.codeMeta
            tf.textColor = .secondaryLabelColor
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            $0.addSubview(tf); $0.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: $0.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: $0.trailingAnchor),
                tf.centerYAnchor.constraint(equalTo: $0.centerYAnchor),
            ])
        }
        // In side-by-side the chevron column is hidden, so carry the collapse glyph inline.
        let prefix = collapsed.map { ($0 ? "▸ " : "▾ ") } ?? ""
        cell.textField?.stringValue = prefix + text
        return cell
    }

    /// One side-by-side row: removed line (left) and added line (right), each with its own gutter
    /// and per-side background tint. Built as a single content-column cell so the table's column
    /// model stays simple (the unified gutter columns are hidden in this mode).
    private func splitCell(left: DiffLine?, right: DiffLine?) -> NSView {
        let id = NSUserInterfaceItemIdentifier("split")
        let cell = (table.makeView(withIdentifier: id, owner: self) as? SplitCellView)
            ?? SplitCellView(identifier: id)
        cell.configure(left: left, right: right)
        return cell
    }

    private func noticeCell(signal: String, lines: Int) -> NSView {
        let id = NSUserInterfaceItemIdentifier("notice")
        let cell = dequeue(id) {
            let tf = NSTextField(labelWithString: "")
            tf.font = Theme.Font.secondary
            tf.textColor = .secondaryLabelColor
            tf.translatesAutoresizingMaskIntoConstraints = false
            $0.addSubview(tf); $0.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: $0.leadingAnchor, constant: 8),
                tf.centerYAnchor.constraint(equalTo: $0.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = lines > 0
            ? "Collapsed \(signal) — \(lines) changed line\(lines == 1 ? "" : "s"). Use “Show anyway” above."
            : "Binary file — no textual diff."
        return cell
    }

    private func dequeue(_ id: NSUserInterfaceItemIdentifier, make: (NSTableCellView) -> Void) -> NSTableCellView {
        if let reused = table.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return reused }
        let cell = NSTableCellView()
        cell.identifier = id
        make(cell)
        return cell
    }
}

// MARK: - Row background

private final class DiffRowView: NSTableRowView {
    var fill: NSColor = .clear
    override func drawBackground(in dirtyRect: NSRect) {
        fill.setFill()
        dirtyRect.fill()
    }
}

// MARK: - Side-by-side line cell

/// Renders one row of a side-by-side diff: old line (left half) and new line (right half), each
/// with its own line-number gutter and add/remove background tint. Two halves split the content
/// column down the middle; churn (whitespace/moved) recedes to a muted tone with no wash, matching
/// the unified renderer.
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
            bg.wantsLayer = true
            bg.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bg)
        }
        for g in [leftGutter, rightGutter] {
            g.font = Theme.Font.codeGutter
            g.alignment = .right
            g.textColor = .tertiaryLabelColor
            g.translatesAutoresizingMaskIntoConstraints = false
        }
        for t in [leftText, rightText] {
            t.font = Theme.Font.code()
            t.lineBreakMode = .byClipping
            t.translatesAutoresizingMaskIntoConstraints = false
        }
        [leftGutter, leftText, rightGutter, rightText].forEach(addSubview)

        let g = DiffViewController.sideGutter
        NSLayoutConstraint.activate([
            leftBG.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftBG.topAnchor.constraint(equalTo: topAnchor),
            leftBG.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftBG.trailingAnchor.constraint(equalTo: centerXAnchor),
            rightBG.leadingAnchor.constraint(equalTo: centerXAnchor),
            rightBG.topAnchor.constraint(equalTo: topAnchor),
            rightBG.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightBG.trailingAnchor.constraint(equalTo: trailingAnchor),

            leftGutter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            leftGutter.widthAnchor.constraint(equalToConstant: g - 6),
            leftGutter.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftText.leadingAnchor.constraint(equalTo: leftGutter.trailingAnchor, constant: 4),
            leftText.trailingAnchor.constraint(lessThanOrEqualTo: centerXAnchor, constant: -4),
            leftText.centerYAnchor.constraint(equalTo: centerYAnchor),

            rightGutter.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 6),
            rightGutter.widthAnchor.constraint(equalToConstant: g - 6),
            rightGutter.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightText.leadingAnchor.constraint(equalTo: rightGutter.trailingAnchor, constant: 4),
            rightText.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            rightText.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(left: DiffLine?, right: DiffLine?) {
        configureSide(gutter: leftGutter, text: leftText, line: left, isOld: true)
        configureSide(gutter: rightGutter, text: rightText, line: right, isOld: false)
        leftBG.layer?.backgroundColor = Self.background(for: left).cgColor
        rightBG.layer?.backgroundColor = Self.background(for: right).cgColor
    }

    private func configureSide(gutter: NSTextField, text: NSTextField, line: DiffLine?, isOld: Bool) {
        guard let line else { gutter.stringValue = ""; text.stringValue = ""; return }
        gutter.stringValue = (isOld ? line.oldLineNumber : line.newLineNumber).map(String.init) ?? ""
        let marker: String
        switch line.kind {
        case .added:   marker = "+"; text.textColor = Theme.Color.addedText
        case .removed: marker = "−"; text.textColor = Theme.Color.removedText
        case .context: marker = " "; text.textColor = .labelColor
        }
        if line.change != .substantive {
            text.textColor = .tertiaryLabelColor   // churn recedes, same as unified
            text.toolTip = line.change == .whitespace ? "Whitespace-only change"
                                                      : "Moved code — appears elsewhere in this diff"
        } else {
            text.toolTip = nil
        }
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

// MARK: - Diff table (click to toggle hunks)

private final class DiffTableView: NSTableView {
    var onToggleHunk: ((Int) -> Void)?
    var hunkIndexProvider: ((Int) -> Int?)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, let index = hunkIndexProvider?(row) {
            onToggleHunk?(index)
            return
        }
        super.mouseDown(with: event)
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
        showButton.target = self
        showButton.action = #selector(expandTapped)
        showButton.isHidden = true
        showButton.translatesAutoresizingMaskIntoConstraints = false

        focusButton.bezelStyle = .accessoryBarAction
        focusButton.controlSize = .small
        focusButton.font = Theme.Font.secondary
        focusButton.setButtonType(.pushOnPushOff)
        focusButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle",
                                    accessibilityDescription: "Focus changes")
        focusButton.imagePosition = .imageLeading
        focusButton.target = self
        focusButton.action = #selector(focusTapped)
        focusButton.isHidden = true
        focusButton.toolTip = "Hide whitespace-only and moved lines"
        focusButton.translatesAutoresizingMaskIntoConstraints = false

        modeButton.bezelStyle = .accessoryBarAction
        modeButton.controlSize = .small
        modeButton.setButtonType(.pushOnPushOff)
        modeButton.imagePosition = .imageOnly
        modeButton.target = self
        modeButton.action = #selector(modeTapped)
        modeButton.toolTip = "Side-by-side view"
        modeButton.translatesAutoresizingMaskIntoConstraints = false

        areaBadgeStack.orientation = .horizontal
        areaBadgeStack.translatesAutoresizingMaskIntoConstraints = false
        areaBadgeStack.isHidden = true

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, areaBadgeStack, pathLabel, signalStack, showButton, focusButton, modeButton, statLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setCustomSpacing(10, after: pathLabel)
        addSubview(row)
        addSubview(divider)

        let rowTrailing = row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Metric.pad)
        rowTrailing.priority = .defaultHigh   // yields only at impossible (0-width) startup sizes
        clipsToBounds = true

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metric.pad),
            rowTrailing,
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -8),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 44),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func expandTapped() { onExpandNoise?() }
    @objc private func focusTapped() { onToggleFocus?() }
    @objc private func modeTapped() { onToggleMode?() }

    /// Reflect focus state and offer the toggle only when there's churn to hide.
    func setFocus(_ on: Bool, churnLines: Int) {
        focusButton.isHidden = churnLines == 0
        focusButton.state = on ? .on : .off
        focusButton.title = on ? "\(churnLines) hidden" : "Focus"
    }

    /// Reflect inline vs side-by-side; the glyph shows the layout the button switches *to*.
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
            default:         badgeTint = .systemBlue   // NEW (untracked)
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
            signalStack.addArrangedSubview(BadgeLabel(text: signal.label, tint: signal.tint, font: Theme.Font.caption))
        }
    }

    func setNoiseCollapsed(_ collapsed: Bool) {
        showButton.isHidden = !collapsed
    }
}
