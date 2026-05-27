import AppKit
import GitData
import Presenters

/// The right column: the core reading experience. The brief asks for a calm,
/// typography-led canvas — not a patch stream. We give the diff generous spacing,
/// soft add/remove tints, a clear file header, collapsible hunks, and automatic
/// collapse of low-signal noise (lockfiles, generated files) that stays one click away.
final class DiffViewController: NSViewController, PresenterObserving {

    var presenter: CommitDetailPresenter? {
        didSet {
            oldValue?.removeObserver(self)
            presenter?.addObserver(self)
            reload()
        }
    }

    private enum Row {
        case hunkHeader(index: Int, text: String)
        case line(DiffLine)
        case collapsedNotice(signal: String, lines: Int)
    }

    private let header = DiffHeaderView()
    private let table = DiffTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Select a commit to read its changes")

    private var rows: [Row] = []
    private var currentFileID: DiffFile.ID?
    private var collapsedHunks: Set<Int> = []
    private var noiseExpanded = false

    // MARK: - Lifecycle

    override func loadView() {
        let oldCol = gutterColumn("old")
        let newCol = gutterColumn("new")
        let contentCol = NSTableColumn(identifier: .init("content"))
        contentCol.resizingMask = .autoresizingMask
        table.addTableColumn(oldCol)
        table.addTableColumn(newCol)
        table.addTableColumn(contentCol)
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
            header.topAnchor.constraint(equalTo: container.topAnchor),
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

    private func gutterColumn(_ id: String) -> NSTableColumn {
        let col = NSTableColumn(identifier: .init(id))
        col.width = 46; col.minWidth = 46; col.maxWidth = 46
        col.resizingMask = []
        return col
    }

    // MARK: - PresenterObserving

    func presenterDidUpdate(_ presenter: AnyObject) { reload() }

    private func reload() {
        let selected = presenter?.selectedFile
        let file = presenter?.files.first { $0.id == selected }

        let hasContent = file != nil
        emptyLabel.isHidden = hasContent
        header.isHidden = !hasContent
        scroll.isHidden = !hasContent

        if selected != currentFileID {
            currentFileID = selected
            collapsedHunks = []
            noiseExpanded = false
        }

        guard let file else { rows = []; table.reloadData(); return }
        let analysis = FileAnalysis.analyze(file)
        header.configure(with: analysis)
        rebuildRows()
    }

    private func rebuildRows() {
        guard let file = presenter?.files.first(where: { $0.id == currentFileID }) else {
            rows = []; table.reloadData(); return
        }
        let analysis = FileAnalysis.analyze(file)

        // Auto-collapse low-signal noise until the user opts in.
        if analysis.isNoise && !noiseExpanded {
            let label = analysis.signals.first(where: { $0 == .lockfile || $0 == .generated || $0 == .dependency })?.label ?? "noise"
            rows = [.collapsedNotice(signal: label, lines: file.additions + file.deletions)]
            header.setNoiseCollapsed(true)
            table.reloadData()
            return
        }
        header.setNoiseCollapsed(false)

        var built: [Row] = []
        for (i, hunk) in file.hunks.enumerated() {
            built.append(.hunkHeader(index: i, text: hunk.header))
            if !collapsedHunks.contains(i) {
                for line in hunk.lines { built.append(.line(line)) }
            }
        }
        if file.hunks.isEmpty && file.isBinary {
            built = [.collapsedNotice(signal: "binary", lines: 0)]
        }
        rows = built
        table.reloadData()
        if !rows.isEmpty { table.scrollRowToVisible(0) }
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
        switch rows[row] {
        case .hunkHeader: return Theme.Metric.hunkHeaderHeight
        case .collapsedNotice: return 44
        case .line: return Theme.Metric.diffLineHeight
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = DiffRowView()
        switch rows[row] {
        case .hunkHeader:
            rv.fill = Theme.Color.hunkBackground
        case .collapsedNotice:
            rv.fill = .clear
        case .line(let l):
            switch l.kind {
            case .added:   rv.fill = Theme.Color.addedBackground
            case .removed: rv.fill = Theme.Color.removedBackground
            case .context: rv.fill = .clear
            }
        }
        return rv
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let colID = tableColumn?.identifier.rawValue ?? ""
        switch rows[row] {
        case .hunkHeader(let index, let text):
            if colID == "old" {
                return chevronCell(collapsed: collapsedHunks.contains(index))
            }
            if colID != "content" { return gutterCell("") }
            return hunkHeaderCell(text)
        case .collapsedNotice(let signal, let lines):
            if colID != "content" { return gutterCell("") }
            return noticeCell(signal: signal, lines: lines)
        case .line(let line):
            switch colID {
            case "old": return gutterCell(line.oldLineNumber.map(String.init) ?? "")
            case "new": return gutterCell(line.newLineNumber.map(String.init) ?? "")
            default:    return contentCell(line)
            }
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

    private func hunkHeaderCell(_ text: String) -> NSView {
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
        cell.textField?.stringValue = text
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
    private let pathLabel = NSTextField(labelWithString: "")
    private let statLabel = NSTextField(labelWithString: "")
    private let signalStack = NSStackView()
    private let showButton = NSButton(title: "Show anyway", target: nil, action: nil)
    private let divider = NSBox()

    var onExpandNoise: (() -> Void)?

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

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, pathLabel, signalStack, showButton, statLabel])
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

    func configure(with fa: FileAnalysis) {
        let tint = Theme.Color.statusColor(fa.statusKind)
        icon.image = NSImage(systemSymbolName: fa.iconName, accessibilityDescription: nil)
        icon.contentTintColor = tint
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
