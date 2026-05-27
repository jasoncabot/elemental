import AppKit
import GitData
import Presenters

@MainActor
protocol FilesViewControllerDelegate: AnyObject {
    func filesViewController(_ vc: FilesViewController, didSelectFile id: DiffFile.ID?)
}

/// The middle column: a lightweight architectural view of the change.
/// Files are grouped by subsystem with heuristic signals (config/deps/generated…),
/// per-file change magnitude, and a risk marker. The active review mode controls
/// grouping and ordering — Narrative groups by subsystem, Files is path-true, Risk
/// surfaces dangerous changes first.
final class FilesViewController: NSViewController, PresenterObserving {
    weak var delegate: FilesViewControllerDelegate?

    var presenter: CommitDetailPresenter? {
        didSet {
            oldValue?.removeObserver(self)
            presenter?.addObserver(self)
            rebuild()
        }
    }

    var reviewMode: ReviewMode = .narrative {
        didSet { guard reviewMode != oldValue else { return }; rebuild() }
    }

    var filter: String = "" {
        didSet { guard filter != oldValue else { return }; rebuild() }
    }

    private enum Node {
        case group(Subsystem)
        case file(FileAnalysis)
    }

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No changes")

    private var groups: [Subsystem] = []
    private var isUpdatingSelection = false

    // MARK: - Lifecycle

    override func loadView() {
        let col = NSTableColumn(identifier: .init("file"))
        col.resizingMask = .autoresizingMask
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.rowHeight = Theme.Metric.fileRowHeight
        outlineView.focusRingType = .none
        outlineView.indentationPerLevel = 14
        outlineView.selectionHighlightStyle = .regular
        outlineView.style = .inset
        outlineView.autosaveExpandedItems = false
        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        headerLabel.font = Theme.Font.sectionHeader
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerBar = NSView()
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerLabel)

        emptyLabel.font = Theme.Font.secondary
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(headerBar)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 34),
            headerLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 16),
            headerLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        view = container
    }

    // MARK: - PresenterObserving

    func presenterDidUpdate(_ presenter: AnyObject) { rebuild() }

    private func rebuild() {
        let allFiles = presenter?.files ?? []
        let files = filter.isEmpty
            ? allFiles
            : allFiles.filter { $0.displayPath.localizedCaseInsensitiveContains(filter) }

        // Boxes capture the data they wrap, so they must be rebuilt whenever the data
        // does — otherwise a reused box (e.g. a group named "App") would still vend the
        // previous repo's files.
        groupBoxes.removeAll()
        fileBoxes.removeAll()
        groups = FileOrganizer.organize(files, mode: reviewMode)

        let total = files.count
        let adds = files.reduce(0) { $0 + $1.additions }
        let dels = files.reduce(0) { $0 + $1.deletions }
        headerLabel.stringValue = total == 0
            ? "CHANGES"
            : "\(total) FILE\(total == 1 ? "" : "S")   +\(adds)  −\(dels)"
        emptyLabel.isHidden = total > 0

        outlineView.reloadData()

        // In Risk/File modes there is a single anonymous group — expand everything.
        for group in groups { outlineView.expandItem(boxed(group)) }
        // Cache boxes so expansion + selection share identity.
        syncSelection()
    }

    private func syncSelection() {
        guard let selected = presenter?.selectedFile else { return }
        for group in groups {
            if let fa = group.files.first(where: { $0.file.id == selected }) {
                let row = outlineView.row(forItem: boxed(fa))
                if row >= 0, outlineView.selectedRow != row {
                    isUpdatingSelection = true
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    isUpdatingSelection = false
                }
                return
            }
        }
    }

    // MARK: - Identity boxing
    // NSOutlineView needs stable reference items; we memoize boxes per rebuild.

    private final class Box: NSObject {
        let node: Node
        init(_ node: Node) { self.node = node }
    }
    private var groupBoxes: [String: Box] = [:]
    private var fileBoxes: [String: Box] = [:]

    private func boxed(_ group: Subsystem) -> Box {
        if let b = groupBoxes[group.name] { return b }
        let b = Box(.group(group)); groupBoxes[group.name] = b; return b
    }
    private func boxed(_ file: FileAnalysis) -> Box {
        if let b = fileBoxes[file.file.id] { return b }
        let b = Box(.file(file)); fileBoxes[file.file.id] = b; return b
    }
}

// MARK: - Data source

extension FilesViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            // A single empty-named group is rendered flat (no group header).
            if groups.count == 1, groups[0].name.isEmpty { return groups[0].files.count }
            return groups.count
        }
        guard let box = item as? Box, case .group(let g) = box.node else { return 0 }
        return g.files.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            if groups.count == 1, groups[0].name.isEmpty { return boxed(groups[0].files[index]) }
            return boxed(groups[index])
        }
        guard let box = item as? Box, case .group(let g) = box.node else { return Box(.group(Subsystem(name: "", files: []))) }
        return boxed(g.files[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let box = item as? Box, case .group = box.node else { return false }
        return true
    }
}

// MARK: - Delegate

extension FilesViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let box = item as? Box else { return Theme.Metric.fileRowHeight }
        if case .group = box.node { return Theme.Metric.groupRowHeight }
        return Theme.Metric.fileRowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let box = item as? Box else { return nil }
        switch box.node {
        case .group(let g):
            let id = NSUserInterfaceItemIdentifier("GroupCell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? SubsystemHeaderView)
                ?? SubsystemHeaderView(identifier: id)
            cell.configure(with: g)
            return cell
        case .file(let fa):
            let id = NSUserInterfaceItemIdentifier("FileCell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? FileRowView)
                ?? FileRowView(identifier: id)
            cell.configure(with: fa, showDirectory: reviewMode != .narrative)
            return cell
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let box = outlineView.item(atRow: row) as? Box,
              case .file(let fa) = box.node else { return }
        delegate?.filesViewController(self, didSelectFile: fa.file.id)
    }
}

// MARK: - Subsystem header cell

private final class SubsystemHeaderView: NSTableCellView {
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let riskDot = NSView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = Theme.Font.fileGroup
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = Theme.Font.caption
        countLabel.textColor = .tertiaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        riskDot.wantsLayer = true
        riskDot.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon); addSubview(nameLabel); addSubview(countLabel); addSubview(riskDot)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            riskDot.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            riskDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            riskDot.widthAnchor.constraint(equalToConstant: 6),
            riskDot.heightAnchor.constraint(equalToConstant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: riskDot.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        riskDot.layer?.cornerRadius = 3
    }

    func configure(with group: Subsystem) {
        nameLabel.stringValue = group.displayName
        countLabel.stringValue = "+\(group.additions)  −\(group.deletions)"
        riskDot.layer?.backgroundColor = group.risk == .low ? NSColor.clear.cgColor : group.risk.tint.cgColor
        riskDot.isHidden = group.risk == .low
    }
}

// MARK: - File row cell

private final class FileRowView: NSTableCellView {
    private let statusBar = NSView()
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let dirLabel = NSTextField(labelWithString: "")
    private let signalStack = NSStackView()
    private let statLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        statusBar.wantsLayer = true
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)

        nameLabel.font = Theme.Font.file
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dirLabel.font = Theme.Font.caption
        dirLabel.textColor = .tertiaryLabelColor
        dirLabel.lineBreakMode = .byTruncatingHead
        dirLabel.translatesAutoresizingMaskIntoConstraints = false
        dirLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        signalStack.orientation = .horizontal
        signalStack.spacing = 3
        signalStack.translatesAutoresizingMaskIntoConstraints = false
        signalStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        statLabel.font = Theme.Font.caption
        statLabel.alignment = .right
        statLabel.translatesAutoresizingMaskIntoConstraints = false
        statLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let nameRow = NSStackView(views: [nameLabel, dirLabel])
        nameRow.orientation = .horizontal
        nameRow.spacing = 6
        nameRow.alignment = .firstBaseline
        nameRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(statusBar); addSubview(icon); addSubview(nameRow)
        addSubview(signalStack); addSubview(statLabel)

        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            statusBar.widthAnchor.constraint(equalToConstant: 3),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),

            nameRow.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            nameRow.centerYAnchor.constraint(equalTo: centerYAnchor),

            signalStack.leadingAnchor.constraint(greaterThanOrEqualTo: nameRow.trailingAnchor, constant: 6),
            signalStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            statLabel.leadingAnchor.constraint(equalTo: signalStack.trailingAnchor, constant: 6),
            statLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        statusBar.layer?.cornerRadius = 1.5
    }

    func configure(with fa: FileAnalysis, showDirectory: Bool) {
        let tint = Theme.Color.statusColor(fa.statusKind)
        statusBar.layer?.backgroundColor = tint.cgColor

        icon.image = NSImage(systemSymbolName: fa.iconName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        icon.contentTintColor = fa.isNoise ? .tertiaryLabelColor : .secondaryLabelColor

        nameLabel.stringValue = fa.fileName
        nameLabel.textColor = fa.isNoise ? .secondaryLabelColor : .labelColor

        dirLabel.stringValue = (showDirectory && !fa.directory.isEmpty) ? fa.directory : ""
        dirLabel.isHidden = dirLabel.stringValue.isEmpty
        toolTip = fa.displayPath

        signalStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for signal in fa.signals.prefix(2) {
            signalStack.addArrangedSubview(BadgeLabel(text: signal.label, tint: signal.tint, font: Theme.Font.caption))
        }

        let stat = NSMutableAttributedString()
        if fa.file.additions > 0 {
            stat.append(NSAttributedString(string: "+\(fa.file.additions) ",
                attributes: [.foregroundColor: Theme.Color.addStat, .font: Theme.Font.caption]))
        }
        if fa.file.deletions > 0 {
            stat.append(NSAttributedString(string: "−\(fa.file.deletions)",
                attributes: [.foregroundColor: Theme.Color.delStat, .font: Theme.Font.caption]))
        }
        statLabel.attributedStringValue = stat
    }
}
