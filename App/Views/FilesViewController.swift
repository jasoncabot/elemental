import AppKit
import GitData
import Presenters

@MainActor
protocol FilesViewControllerDelegate: AnyObject {
    func filesViewController(_ vc: FilesViewController, didSelect selection: DetailSelection?)
}

/// The middle column: a lightweight architectural view of the change.
/// Files are grouped by subsystem with heuristic signals (config/deps/generated…),
/// per-file change magnitude, and a risk marker. The active review mode controls
/// grouping and ordering — Narrative groups by subsystem, Files is path-true, Risk
/// surfaces dangerous changes first.
final class FilesViewController: NSViewController, PresenterObserving {
    weak var delegate: FilesViewControllerDelegate?

    var source: (any DetailSource)? {
        didSet {
            oldValue?.removeObserver(self)
            source?.addObserver(self)
            collapsedKeys.removeAll()
            rebuild()
        }
    }

    var reviewMode: ReviewMode = .narrative {
        didSet {
            guard reviewMode != oldValue else { return }
            collapsedKeys.removeAll()
            rebuild()
        }
    }

    var filter: String = "" {
        didSet { guard filter != oldValue else { return }; rebuild() }
    }

    private enum Node {
        case group(DetailSection)
        /// A directory folder inside a working-copy area section.
        case dir(area: DetailArea, directory: String, files: [FileAnalysis])
        /// `area` is nil for commit review; set for working-copy areas so the same path under both
        /// Staged and Unstaged remains two distinct, independently-selectable rows.
        case file(area: DetailArea?, FileAnalysis)
    }

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let commitSummary = CommitSummaryView()
    private let emptyLabel = NSTextField(labelWithString: "No changes")

    private var sections: [DetailSection] = []
    private var isUpdatingSelection = false
    /// Keys of items the user has manually collapsed. Persists across rebuilds so that
    /// changing the selected diff file doesn't reset expand/collapse state.
    private var collapsedKeys: Set<String> = []

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

        commitSummary.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = Theme.Font.secondary
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(commitSummary)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            commitSummary.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor)
                .id("FilesView.commitSummary.top"),
            commitSummary.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                .id("FilesView.commitSummary.leading"),
            commitSummary.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                .id("FilesView.commitSummary.trailing"),

            scrollView.topAnchor.constraint(equalTo: commitSummary.bottomAnchor)
                .id("FilesView.scrollView.top"),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                .id("FilesView.scrollView.leading"),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                .id("FilesView.scrollView.trailing"),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
                .id("FilesView.scrollView.bottom"),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor)
                .id("FilesView.emptyLabel.centerX"),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                .id("FilesView.emptyLabel.centerY"),
        ])

        view = container
    }

    // MARK: - PresenterObserving

    func presenterDidUpdate(_ presenter: AnyObject) { rebuild() }

    private func rebuild() {
        let rawSections = source?.sections(reviewMode: reviewMode) ?? []
        // Apply the file-name filter within each section, dropping sections left empty.
        sections = rawSections.compactMap { section in
            guard !filter.isEmpty else { return section }
            let kept = section.files.filter { $0.displayPath.localizedCaseInsensitiveContains(filter) }
            return kept.isEmpty ? nil : DetailSection(title: section.title, area: section.area, files: kept)
        }

        // Boxes capture the data they wrap, so they must be rebuilt whenever the data does —
        // otherwise a reused box would still vend the previous selection's files.
        groupBoxes.removeAll()
        dirBoxes.removeAll()
        fileBoxes.removeAll()
        dirGroupCache.removeAll()

        let files = sections.flatMap(\.files)
        let total = files.count
        let adds = files.reduce(0) { $0 + $1.file.additions }
        let dels = files.reduce(0) { $0 + $1.file.deletions }
        commitSummary.configure(header: source?.header ?? .none)
        commitSummary.setStats(total == 0
            ? "CHANGES"
            : "\(total) FILE\(total == 1 ? "" : "S")   +\(adds)  −\(dels)")
        emptyLabel.isHidden = total > 0

        outlineView.reloadData()

        // Expand groups and directory nodes, but honour any collapse state the user set.
        for section in sections {
            let sectionBox = boxed(section)
            if !collapsedKeys.contains(collapseKey(for: sectionBox)) {
                outlineView.expandItem(sectionBox)
            }
            if let area = section.area {
                for (dir, files) in dirGroups(in: section) {
                    let dirBox = boxedDir(area: area, dir: dir, files: files)
                    if !collapsedKeys.contains(collapseKey(for: dirBox)) {
                        outlineView.expandItem(dirBox)
                    }
                }
            }
        }
        syncSelection()
    }

    private func syncSelection() {
        guard let selected = source?.selection else { return }
        for section in sections {
            guard section.area == selected.area else { continue }
            if let fa = section.files.first(where: { matches(selected, area: section.area, fa: $0) }) {
                let row = outlineView.row(forItem: boxed(fa, area: section.area))
                if row >= 0, outlineView.selectedRow != row {
                    // If the row is already visible, preserve the scroll position — selectRowIndexes
                    // can scroll the table even when the target row is on screen.
                    let rowRect = outlineView.rect(ofRow: row)
                    let alreadyVisible = outlineView.visibleRect.intersects(rowRect)
                    let savedOrigin = scrollView.contentView.bounds.origin
                    isUpdatingSelection = true
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    isUpdatingSelection = false
                    if alreadyVisible {
                        scrollView.contentView.scroll(to: savedOrigin)
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                }
                return
            }
        }
    }

    /// Commit selection keys by `DiffFile.id`; working-copy selection keys by path (so the same
    /// path can be selected independently under Staged and Unstaged).
    private func matches(_ sel: DetailSelection, area: DetailArea?, fa: FileAnalysis) -> Bool {
        guard area == sel.area else { return false }
        return area == nil ? fa.file.id == sel.fileID : fa.displayPath == sel.fileID
    }

    private func selection(for fa: FileAnalysis, area: DetailArea?) -> DetailSelection {
        area == nil ? DetailSelection(area: nil, fileID: fa.file.id)
                    : DetailSelection(area: area, fileID: fa.displayPath)
    }

    /// Whether the only section is anonymous (commit Risk/File mode), so it renders flat.
    private var isFlat: Bool {
        sections.count == 1 && (sections[0].title ?? "").isEmpty
    }

    // MARK: - Identity boxing
    // NSOutlineView needs stable reference items; we memoize boxes per rebuild.

    private final class Box: NSObject {
        let node: Node
        init(_ node: Node) { self.node = node }
    }
    private var groupBoxes:    [String: Box] = [:]
    private var dirBoxes:      [String: Box] = [:]
    private var fileBoxes:     [String: Box] = [:]
    private var dirGroupCache: [String: [(dir: String, files: [FileAnalysis])]] = [:]

    private func boxKey(_ area: DetailArea?, _ id: String) -> String {
        "\(area.map(String.init(describing:)) ?? "_"):\(id)"
    }

    private func boxed(_ section: DetailSection) -> Box {
        let key = boxKey(section.area, section.title ?? "")
        if let b = groupBoxes[key] { return b }
        let b = Box(.group(section)); groupBoxes[key] = b; return b
    }
    private func boxedDir(area: DetailArea, dir: String, files: [FileAnalysis]) -> Box {
        let key = boxKey(area, "dir:\(dir)")
        if let b = dirBoxes[key] { return b }
        let b = Box(.dir(area: area, directory: dir, files: files)); dirBoxes[key] = b; return b
    }
    private func boxed(_ file: FileAnalysis, area: DetailArea?) -> Box {
        let key = boxKey(area, file.displayPath + ":" + file.file.id)
        if let b = fileBoxes[key] { return b }
        let b = Box(.file(area: area, file)); fileBoxes[key] = b; return b
    }

    private func collapseKey(for box: Box) -> String {
        switch box.node {
        case .group(let section): return boxKey(section.area, section.title ?? "")
        case .dir(let area, let dir, _): return boxKey(area, "dir:\(dir)")
        case .file: return ""
        }
    }

    /// Groups files in a working-copy section by their directory, preserving insertion order.
    /// Memoized per rebuild — the result for a given section is computed at most once.
    private func dirGroups(in section: DetailSection) -> [(dir: String, files: [FileAnalysis])] {
        let key = boxKey(section.area, section.title ?? "")
        if let cached = dirGroupCache[key] { return cached }
        var order: [String] = []
        var groups: [String: [FileAnalysis]] = [:]
        for fa in section.files {
            let dir = fa.directory
            if groups[dir] == nil { order.append(dir) }
            groups[dir, default: []].append(fa)
        }
        let result = order.map { (dir: $0, files: groups[$0]!) }
        dirGroupCache[key] = result
        return result
    }
}

// MARK: - Data source

extension FilesViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            if isFlat { return sections.first?.files.count ?? 0 }
            return sections.count
        }
        guard let box = item as? Box else { return 0 }
        switch box.node {
        case .group(let section):
            return section.area != nil ? dirGroups(in: section).count : section.files.count
        case .dir(_, _, let files):
            return files.count
        case .file:
            return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let fallback = Box(.group(DetailSection(title: "", area: nil, files: [])))
        if item == nil {
            if isFlat {
                guard !sections.isEmpty, index < sections[0].files.count else { return fallback }
                return boxed(sections[0].files[index], area: sections[0].area)
            }
            guard index < sections.count else { return fallback }
            return boxed(sections[index])
        }
        guard let box = item as? Box else { return fallback }
        switch box.node {
        case .group(let section):
            if section.area != nil {
                let dirs = dirGroups(in: section)
                guard index < dirs.count else { return fallback }
                let (dir, files) = dirs[index]
                return boxedDir(area: section.area!, dir: dir, files: files)
            }
            guard index < section.files.count else { return fallback }
            return boxed(section.files[index], area: nil)
        case .dir(let area, _, let files):
            guard index < files.count else { return fallback }
            return boxed(files[index], area: area)
        case .file:
            return fallback
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let box = item as? Box else { return false }
        switch box.node {
        case .group, .dir: return true
        case .file:        return false
        }
    }
}

// MARK: - Delegate

extension FilesViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let box = item as? Box else { return Theme.Metric.fileRowHeight }
        switch box.node {
        case .group: return Theme.Metric.groupRowHeight
        case .dir:   return Theme.Metric.groupRowHeight
        case .file:  return Theme.Metric.fileRowHeight
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let box = item as? Box else { return nil }
        switch box.node {
        case .group(let section):
            let id = NSUserInterfaceItemIdentifier("GroupCell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? SubsystemHeaderView)
                ?? SubsystemHeaderView(identifier: id)
            cell.configure(with: Subsystem(name: section.title ?? "", files: section.files),
                           isArea: section.area != nil)
            return cell
        case .dir(_, let directory, _):
            let id = NSUserInterfaceItemIdentifier("DirCell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? DirRowView)
                ?? DirRowView(identifier: id)
            cell.configure(directory: directory.isEmpty ? "/" : directory)
            return cell
        case .file(let area, let fa):
            let id = NSUserInterfaceItemIdentifier("FileCell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? FileRowView)
                ?? FileRowView(identifier: id)
            // In working-copy mode files live under directory nodes, so no inline directory needed.
            // In commit mode (area == nil) show directory when not in narrative grouping.
            cell.configure(with: fa, showDirectory: area == nil && reviewMode != .narrative)
            return cell
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let box = notification.userInfo?["NSObject"] as? Box else { return }
        let k = collapseKey(for: box)
        if !k.isEmpty { collapsedKeys.insert(k) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let box = notification.userInfo?["NSObject"] as? Box else { return }
        collapsedKeys.remove(collapseKey(for: box))
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let box = outlineView.item(atRow: row) as? Box,
              case .file(let area, let fa) = box.node else { return }
        delegate?.filesViewController(self, didSelect: selection(for: fa, area: area))
    }
}

// MARK: - Subsystem header cell

@objc(SubsystemHeaderView)
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
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
                .id("SubsystemHeader.icon.leading"),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("SubsystemHeader.icon.centerY"),
            icon.widthAnchor.constraint(equalToConstant: 14)
                .id("SubsystemHeader.icon.width"),
            riskDot.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
                .id("SubsystemHeader.riskDot.leading"),
            riskDot.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("SubsystemHeader.riskDot.centerY"),
            riskDot.widthAnchor.constraint(equalToConstant: 6)
                .id("SubsystemHeader.riskDot.width"),
            riskDot.heightAnchor.constraint(equalToConstant: 6)
                .id("SubsystemHeader.riskDot.height"),
            nameLabel.leadingAnchor.constraint(equalTo: riskDot.trailingAnchor, constant: 6)
                .id("SubsystemHeader.nameLabel.leading"),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("SubsystemHeader.nameLabel.centerY"),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 6)
                .id("SubsystemHeader.countLabel.leading"),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
                .id("SubsystemHeader.countLabel.trailing"),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("SubsystemHeader.countLabel.centerY"),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        riskDot.layer?.cornerRadius = 3
    }

    func configure(with group: Subsystem, isArea: Bool = false) {
        // Working-copy area headers ("Staged"/"Unstaged"/"Untracked") read as trees, not folders.
        icon.image = NSImage(systemSymbolName: isArea ? "tray.full" : "folder.fill",
                             accessibilityDescription: nil)
        nameLabel.stringValue = group.displayName
        countLabel.stringValue = "+\(group.additions)  −\(group.deletions)"
        riskDot.layer?.backgroundColor = group.risk == .low ? NSColor.clear.cgColor : group.risk.tint.cgColor
        riskDot.isHidden = group.risk == .low
    }
}

// MARK: - Directory row cell (working-copy tree)

@objc(DirRowView)
private final class DirRowView: NSTableCellView {
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = Theme.Font.caption
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(icon); addSubview(nameLabel)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
                .id("DirRow.icon.leading"),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("DirRow.icon.centerY"),
            icon.widthAnchor.constraint(equalToConstant: 13)
                .id("DirRow.icon.width"),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5)
                .id("DirRow.nameLabel.leading"),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("DirRow.nameLabel.centerY"),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
                .id("DirRow.nameLabel.trailing"),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(directory: String) {
        nameLabel.stringValue = directory
    }
}

// MARK: - File row cell

@objc(FileRowView)
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
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor)
                .id("FileRow.statusBar.leading"),
            statusBar.topAnchor.constraint(equalTo: topAnchor, constant: 4)
                .id("FileRow.statusBar.top"),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
                .id("FileRow.statusBar.bottom"),
            statusBar.widthAnchor.constraint(equalToConstant: 3)
                .id("FileRow.statusBar.width"),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
                .id("FileRow.icon.leading"),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("FileRow.icon.centerY"),
            icon.widthAnchor.constraint(equalToConstant: 16)
                .id("FileRow.icon.width"),

            nameRow.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
                .id("FileRow.nameRow.leading"),
            nameRow.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("FileRow.nameRow.centerY"),

            signalStack.leadingAnchor.constraint(greaterThanOrEqualTo: nameRow.trailingAnchor, constant: 6)
                .id("FileRow.signalStack.leading"),
            signalStack.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("FileRow.signalStack.centerY"),
            statLabel.leadingAnchor.constraint(equalTo: signalStack.trailingAnchor, constant: 6)
                .id("FileRow.statLabel.leading"),
            statLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
                .id("FileRow.statLabel.trailing"),
            statLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("FileRow.statLabel.centerY"),
            statLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56)
                .id("FileRow.statLabel.minWidth"),
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
        // Convey add/modify/delete by color (the status bar carries it positionally too); noise
        // recedes regardless of status. Status is also announced via the accessibility label below,
        // so it never depends on color alone.
        nameLabel.textColor = fa.isNoise ? .secondaryLabelColor : Theme.Color.statusText(fa.statusKind)

        dirLabel.stringValue = (showDirectory && !fa.directory.isEmpty) ? fa.directory : ""
        dirLabel.isHidden = dirLabel.stringValue.isEmpty
        toolTip = fa.displayPath
        setAccessibilityLabel("\(Self.statusWord(fa.file.status)): \(fa.displayPath)")

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

    /// Spoken status for VoiceOver — the non-color cue that pairs with the colored filename.
    static func statusWord(_ status: DiffStatus) -> String {
        switch status {
        case .added:       return "Added"
        case .untracked:   return "New"
        case .deleted:     return "Deleted"
        case .modified:    return "Modified"
        case .renamed:     return "Renamed"
        case .copied:      return "Copied"
        case .typeChanged: return "Type changed"
        case .unmerged:    return "Conflicted"
        case .ignored:     return "Ignored"
        }
    }
}

// MARK: - Commit summary (the "why" above the file list)

/// Shows the reviewed commit's message — subject, body, metadata — plus any git note, so the
/// intent behind the change sits alongside the files it touched. Pure git metadata; no AI.
@objc(CommitSummaryView)
private final class CommitSummaryView: NSView {
    private let subjectLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let divider = NSBox()
    private static let hInset: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        subjectLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        subjectLabel.maximumNumberOfLines = 2
        subjectLabel.lineBreakMode = .byTruncatingTail

        metaLabel.font = Theme.Font.secondary
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail

        bodyLabel.font = Theme.Font.secondary
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 6
        bodyLabel.lineBreakMode = .byTruncatingTail

        noteLabel.font = Theme.Font.secondary
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 4
        noteLabel.lineBreakMode = .byTruncatingTail

        statsLabel.font = Theme.Font.caption
        statsLabel.textColor = .tertiaryLabelColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        let labelNames = ["subject", "meta", "body", "note", "stats"]
        for (label, name) in zip([subjectLabel, metaLabel, bodyLabel, noteLabel, statsLabel], labelNames) {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor)
                .id("CommitSummary.\(name).fillWidth")
                .isActive = true
        }

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(divider)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10)
                .id("CommitSummary.stack.top"),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hInset)
                .id("CommitSummary.stack.leading"),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hInset)
                .id("CommitSummary.stack.trailing"),
            stack.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -10)
                .id("CommitSummary.stack.bottom"),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor)
                .id("CommitSummary.divider.leading"),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor)
                .id("CommitSummary.divider.trailing"),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor)
                .id("CommitSummary.divider.bottom"),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Multiline labels need an explicit wrapping width to compute their height.
        let width = bounds.width - Self.hInset * 2
        for label in [subjectLabel, bodyLabel, noteLabel] { label.preferredMaxLayoutWidth = width }
    }

    func setStats(_ text: String) { statsLabel.stringValue = text }

    func configure(header: DetailHeader) {
        switch header {
        case .none:
            [subjectLabel, metaLabel, bodyLabel, noteLabel].forEach { $0.isHidden = true }
        case .commit(let commit, let note):
            configureCommit(commit, note: note)
        case .workingCopy(let branch, let staged, let unstaged, let untracked, let prepared):
            configureWorkingCopy(branch: branch, staged: staged, unstaged: unstaged,
                                 untracked: untracked, prepared: prepared)
        }
    }

    /// The working copy's "why": a draft commit message if git has one prepared, plus the branch
    /// and a staged/unstaged/untracked tally. No SHA exists yet, so there's no git note.
    private func configureWorkingCopy(branch: String?, staged: Int, unstaged: Int,
                                      untracked: Int, prepared: String?) {
        subjectLabel.isHidden = false
        subjectLabel.stringValue = "Uncommitted Changes"
        subjectLabel.textColor = .labelColor

        var parts: [String] = []
        if let branch { parts.append("⎇ \(branch)") }
        parts.append("\(staged) staged")
        parts.append("\(unstaged) unstaged")
        if untracked > 0 { parts.append("\(untracked) untracked") }
        metaLabel.isHidden = false
        metaLabel.stringValue = parts.joined(separator: " · ")
        metaLabel.toolTip = nil

        let draft = (prepared ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        bodyLabel.isHidden = draft.isEmpty
        bodyLabel.stringValue = draft
        bodyLabel.toolTip = draft.isEmpty ? nil : draft

        noteLabel.isHidden = true
        noteLabel.toolTip = nil
        needsLayout = true
    }

    private func configureCommit(_ commit: Commit?, note: CommitDetailPresenter.NoteState) {
        guard let commit else {
            [subjectLabel, metaLabel, bodyLabel, noteLabel].forEach { $0.isHidden = true }
            return
        }
        subjectLabel.isHidden = false
        metaLabel.isHidden = false

        if commit.subject.isEmpty {
            subjectLabel.stringValue = "(no commit message)"
            subjectLabel.textColor = .tertiaryLabelColor
        } else {
            subjectLabel.stringValue = commit.subject
            subjectLabel.textColor = .labelColor
        }

        metaLabel.stringValue =
            "\(commit.author.name) • \(RelativeDate.short(commit.authorDate)) • \(commit.sha.prefix(7))"
        metaLabel.toolTip = RelativeDate.exact(commit.authorDate)

        let body = commit.body.trimmingCharacters(in: .whitespacesAndNewlines)
        bodyLabel.isHidden = body.isEmpty
        bodyLabel.stringValue = body
        bodyLabel.toolTip = body.isEmpty ? nil : body

        // Only a loaded, non-empty note shows; loading and unavailable both stay hidden.
        if case .loaded(let text) = note,
           case let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            noteLabel.isHidden = false
            noteLabel.stringValue = "🗒 \(trimmed)"
            noteLabel.toolTip = trimmed
        } else {
            noteLabel.isHidden = true
            noteLabel.toolTip = nil
        }

        needsLayout = true
    }
}
