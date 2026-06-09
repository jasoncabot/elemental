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

    /// Status/type filter applied to the file list, driven by the funnel control above it.
    private var fileFilter = FileFilter() {
        didSet {
            guard fileFilter != oldValue else { return }
            rebuild()
            updateFilterButton()
        }
    }

    private enum Node {
        case group(DetailSection)
        /// A directory folder inside a working-copy area section.
        case dir(area: DetailArea, directory: String, files: [FileAnalysis])
        /// `area` is nil for commit review; set for working-copy areas so the same path under both
        /// Staged and Unstaged remains two distinct, independently-selectable rows.
        case file(area: DetailArea?, FileAnalysis)
    }

    private let outlineView = FilesOutlineView()
    private let scrollView = NSScrollView()
    private let commitSummary = CommitSummaryView()
    private let headerDivider = NSBox()
    private let emptyLabel = NSTextField(labelWithString: "No changes")
    private let filterBar = NSView()
    private let filterButton = NSButton()
    private var filterBarHeight: NSLayoutConstraint!

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
        outlineView.onContextMenu = { [weak self] row in self?.contextMenu(for: row) }

        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        commitSummary.translatesAutoresizingMaskIntoConstraints = false
        // No callback work needed — the header is a direct subview now, so collapse/expand
        // is a pure auto-layout animation driven from inside CommitSummaryView itself.
        commitSummary.onCollapseToggle = nil

        headerDivider.boxType = .separator
        headerDivider.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = Theme.Font.secondary
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        setupFilterBar()

        let container = NSView()
        container.addSubview(commitSummary)
        container.addSubview(headerDivider)
        container.addSubview(filterBar)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        filterBarHeight = filterBar.heightAnchor.constraint(equalToConstant: 0)
            .id("FilesView.filterBar.height")

        // Header sizing — fully specified, no manual height bookkeeping. The commit summary
        // sits directly in the container with its intrinsic height driving the chain. A
        // multiplier cap (≤ 55% of container) keeps the file list visible even when a commit
        // message is long; the body label truncates instead of inner-scrolling. With nothing
        // wrapping the summary in an NSScrollView, `isHidden` changes inside its NSStackView
        // propagate cleanly through implicit animation.
        let headerCap = commitSummary.heightAnchor.constraint(
            lessThanOrEqualTo: container.heightAnchor, multiplier: 0.55)
            .id("FilesView.commitSummary.cap")
        headerCap.priority = .required

        NSLayoutConstraint.activate([
            commitSummary.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor)
                .id("FilesView.commitSummary.top"),
            commitSummary.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                .id("FilesView.commitSummary.leading"),
            commitSummary.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                .id("FilesView.commitSummary.trailing"),
            headerCap,

            headerDivider.topAnchor.constraint(equalTo: commitSummary.bottomAnchor)
                .id("FilesView.headerDivider.top"),
            headerDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                .id("FilesView.headerDivider.leading"),
            headerDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                .id("FilesView.headerDivider.trailing"),

            filterBar.topAnchor.constraint(equalTo: headerDivider.bottomAnchor)
                .id("FilesView.filterBar.top"),
            filterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                .id("FilesView.filterBar.leading"),
            filterBar.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                .id("FilesView.filterBar.trailing"),
            filterBarHeight,

            scrollView.topAnchor.constraint(equalTo: filterBar.bottomAnchor)
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
        // The funnel only makes sense when there's something to filter; show it once a change is loaded.
        let rawHasFiles = rawSections.contains { !$0.files.isEmpty }
        filterBarHeight.constant = rawHasFiles ? 32 : 0
        filterBar.isHidden = !rawHasFiles

        // Apply the status/type filter within each section, dropping sections left empty.
        sections = rawSections.compactMap { section in
            guard fileFilter.isActive else { return section }
            let kept = section.files.filter { fileFilter.matches($0) }
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
        emptyLabel.stringValue = (total == 0 && fileFilter.isActive) ? "No files match this filter" : "No changes"
        emptyLabel.isHidden = total > 0

        // Save before reloadData — expandItem calls can shift the pixel offset when rows
        // are inserted above the current scroll position.
        let savedOrigin = scrollView.contentView.bounds.origin
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

        scrollView.contentView.scroll(to: savedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
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

    // MARK: - File filter (status / type)

    private func setupFilterBar() {
        filterBar.translatesAutoresizingMaskIntoConstraints = false

        filterButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle",
                                     accessibilityDescription: "Filter files")
        filterButton.bezelStyle = .toolbar
        filterButton.isBordered = false
        filterButton.imagePosition = .imageOnly
        filterButton.contentTintColor = .secondaryLabelColor
        filterButton.toolTip = "Filter files by status and type"
        filterButton.target = self
        filterButton.action = #selector(showFilterMenu)
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        filterBar.addSubview(filterButton)

        NSLayoutConstraint.activate([
            filterButton.trailingAnchor.constraint(equalTo: filterBar.trailingAnchor, constant: -10)
                .id("FilesView.filterButton.trailing"),
            filterButton.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor)
                .id("FilesView.filterButton.centerY"),
        ])
    }

    /// The funnel reads as active (accent-tinted, filled glyph) whenever any filter is set.
    private func updateFilterButton() {
        let active = fileFilter.isActive
        filterButton.contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
        filterButton.image = NSImage(
            systemSymbolName: active ? "line.3.horizontal.decrease.circle.fill"
                                     : "line.3.horizontal.decrease.circle",
            accessibilityDescription: "Filter files")
    }

    /// Statuses offered in the menu, in review-friendly order.
    private static let filterStatuses: [(DiffStatusKind, String)] = [
        (.added, "Added"), (.modified, "Modified"), (.deleted, "Deleted"),
        (.renamed, "Renamed"), (.copied, "Copied"),
    ]
    /// Type/signal facets offered in the menu.
    private static let filterSignals: [(FileSignal, String)] = [
        (.config, "Config"), (.dependency, "Dependencies"), (.schema, "Schema"),
        (.security, "Security"), (.infra, "Infra"), (.test, "Tests"),
        (.docs, "Docs"), (.generated, "Generated"),
    ]

    @objc private func showFilterMenu() {
        let menu = NSMenu()

        let statusHeader = NSMenuItem(title: "Status", action: nil, keyEquivalent: "")
        statusHeader.isEnabled = false
        menu.addItem(statusHeader)
        for (status, title) in Self.filterStatuses {
            let item = NSMenuItem(title: title, action: #selector(toggleStatusFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = status
            item.state = fileFilter.statuses.contains(status) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let typeHeader = NSMenuItem(title: "Type", action: nil, keyEquivalent: "")
        typeHeader.isEnabled = false
        menu.addItem(typeHeader)
        for (signal, title) in Self.filterSignals {
            let item = NSMenuItem(title: title, action: #selector(toggleSignalFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = signal
            item.state = fileFilter.signals.contains(signal) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let hideNoise = NSMenuItem(title: "Hide Noise (lockfiles, generated…)",
                                   action: #selector(toggleHideNoise), keyEquivalent: "")
        hideNoise.target = self
        hideNoise.state = fileFilter.hideNoise ? .on : .off
        menu.addItem(hideNoise)

        if fileFilter.isActive {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Filters", action: #selector(clearFileFilter), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }

        let origin = NSPoint(x: 0, y: filterButton.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: filterButton)
    }

    @objc private func toggleStatusFilter(_ item: NSMenuItem) {
        guard let status = item.representedObject as? DiffStatusKind else { return }
        if fileFilter.statuses.contains(status) { fileFilter.statuses.remove(status) }
        else { fileFilter.statuses.insert(status) }
    }

    @objc private func toggleSignalFilter(_ item: NSMenuItem) {
        guard let signal = item.representedObject as? FileSignal else { return }
        if fileFilter.signals.contains(signal) { fileFilter.signals.remove(signal) }
        else { fileFilter.signals.insert(signal) }
    }

    @objc private func toggleHideNoise() { fileFilter.hideNoise.toggle() }

    @objc private func clearFileFilter() { fileFilter = FileFilter() }

    // MARK: - Context menu

    private func contextMenu(for row: Int) -> NSMenu? {
        guard let box = outlineView.item(atRow: row) as? Box,
              case .file(_, let fa) = box.node else { return nil }

        let menu = NSMenu()

        let pathItem = NSMenuItem(title: "Copy Path",
                                  action: #selector(copyFilePath(_:)),
                                  keyEquivalent: "")
        pathItem.representedObject = fa.displayPath
        pathItem.target = self
        menu.addItem(pathItem)

        let nameItem = NSMenuItem(title: "Copy Filename",
                                  action: #selector(copyFileName(_:)),
                                  keyEquivalent: "")
        nameItem.representedObject = fa.fileName
        nameItem.target = self
        menu.addItem(nameItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open at This Version",
                                  action: #selector(openAtThisVersion(_:)),
                                  keyEquivalent: "")
        openItem.representedObject = fa.file
        openItem.target = self
        menu.addItem(openItem)

        if let repoRoot = source?.repoRootURL {
            let finderItem = NSMenuItem(title: "Show in Finder",
                                        action: #selector(showInFinder(_:)),
                                        keyEquivalent: "")
            finderItem.representedObject = finderURL(for: fa.file, repoRoot: repoRoot)
            finderItem.target = self
            menu.addItem(finderItem)
        }

        return menu
    }

    private func finderURL(for file: DiffFile, repoRoot: URL) -> URL {
        // Deleted files: walk up from the old path until we find an existing directory.
        if file.status == .deleted, let oldPath = file.oldPath {
            var dir = (oldPath as NSString).deletingLastPathComponent
            while !dir.isEmpty && dir != "." {
                let url = repoRoot.appendingPathComponent(dir)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    return url
                }
                dir = (dir as NSString).deletingLastPathComponent
            }
            return repoRoot
        }
        // All other statuses (including renamed/moved): use the destination path.
        return repoRoot.appendingPathComponent(file.displayPath)
    }

    @objc private func showInFinder(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyFilePath(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func copyFileName(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

    @objc private func openAtThisVersion(_ item: NSMenuItem) {
        guard let file = item.representedObject as? DiffFile,
              let source else { return }
        Task { @MainActor [weak self] in
            guard self != nil else { return }
            guard let data = await source.currentBlob(for: file) else { return }
            do {
                let uuid = UUID().uuidString
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("elemental-\(uuid)", isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir,
                                                        withIntermediateDirectories: true)
                let filename = (file.displayPath as NSString).lastPathComponent
                let fileURL = tempDir.appendingPathComponent(filename)
                try data.write(to: fileURL)
                NSWorkspace.shared.open(fileURL)
            } catch {
                // Temp write failed — nothing actionable to surface to the user.
            }
        }
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
///
/// The narrative (subject + body + note) is the centerpiece here: in an agentic-changes
/// workflow people spend more time reading the author's prose than reading the diff itself,
/// so body text reads in the primary label color with comfortable line height, and the
/// SHA / author / date demote themselves into a compact identity strip.
@objc(CommitSummaryView)
private final class CommitSummaryView: NSView {
    private let subjectLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let filesLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")

    private let identityRow = NSStackView()
    private let authorDot = AuthorDot()
    private let authorLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let shaPill = ShaPill()

    /// Horizontal chip strip: conventional-commit type, scope, breaking flag, trailer refs.
    private let chipRow = NSStackView()
    /// Vertical stack of NoteBlockViews — one per loaded note ref. Hidden when empty.
    private let notesStack = NSStackView()
    /// Small disclosure chevron in the identity row. Toggling shows/hides body + notes.
    private let collapseButton = NSButton()
    /// Whether the body + notes are hidden so the file list gets more room. Persists for the session.
    private(set) var isCollapsed = false
    /// Called when the collapse state changes so the parent can re-measure the header height.
    var onCollapseToggle: (() -> Void)?

    private let stack = NSStackView()
    private let statsDivider = NSBox()
    private let statsRow = NSStackView()

    private static let hInset: CGFloat = 20
    private static let topInset: CGFloat = 16
    private static let bottomInset: CGFloat = 12

    // Subject reads as a real headline; body reads as readable prose. Tight on the subject,
    // loose on the body — the body is what people are here to read.
    private static let subjectFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
    private static let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private static let subjectLineMultiple: CGFloat = 1.12
    private static let bodyLineMultiple: CGFloat = 1.42
    private static let bodyMaxLines: Int = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Subject: a real headline. Tight tracking, generous size, primary text.
        subjectLabel.font = Self.subjectFont
        subjectLabel.textColor = .labelColor
        subjectLabel.maximumNumberOfLines = 3
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.allowsDefaultTighteningForTruncation = true
        subjectLabel.cell?.wraps = true

        // Body: PRIMARY text color, system body size, generous line-height for sustained reading.
        bodyLabel.font = Self.bodyFont
        bodyLabel.textColor = .labelColor
        // Soft cap on lines: long agentic narratives truncate with a tooltip rather than
        // pushing the file list off-screen. Vertical compression resistance is lowered so
        // the parent's multiplier cap (≤ 55% of pane) can squeeze the label further when the
        // window is short, leaving every other element in the summary at its intrinsic size.
        bodyLabel.maximumNumberOfLines = Self.bodyMaxLines
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.cell?.wraps = true
        bodyLabel.cell?.isScrollable = false
        bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        // Identity strip: ●  Author Name    2 days ago                  d062863
        authorLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        authorLabel.textColor = .labelColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        dateLabel.font = .systemFont(ofSize: 12, weight: .regular)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        identityRow.orientation = .horizontal
        identityRow.alignment = .centerY
        identityRow.spacing = 8
        identityRow.translatesAutoresizingMaskIntoConstraints = false
        identityRow.addArrangedSubview(authorDot)
        identityRow.setCustomSpacing(8, after: authorDot)
        identityRow.addArrangedSubview(authorLabel)
        identityRow.setCustomSpacing(10, after: authorLabel)
        identityRow.addArrangedSubview(dateLabel)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        identityRow.addArrangedSubview(spacer)
        identityRow.addArrangedSubview(shaPill)

        // Collapse/expand chevron — sits right of the SHA pill, always visible when a commit is shown.
        collapseButton.isBordered = false
        collapseButton.setButtonType(.momentaryPushIn)
        collapseButton.imageScaling = .scaleProportionallyDown
        collapseButton.contentTintColor = .tertiaryLabelColor
        collapseButton.toolTip = "Show/hide commit body and notes"
        collapseButton.target = self
        collapseButton.action = #selector(toggleCollapse)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collapseButton.widthAnchor.constraint(equalToConstant: 16)
                .id("CommitSummary.collapseButton.width"),
            collapseButton.heightAnchor.constraint(equalToConstant: 16)
                .id("CommitSummary.collapseButton.height"),
        ])
        identityRow.addArrangedSubview(collapseButton)
        updateCollapseButton()

        // Chip row: small pills for conv. commit type/scope, trailers, and issue refs.
        chipRow.orientation = .horizontal
        chipRow.alignment = .centerY
        chipRow.spacing = 6
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        chipRow.isHidden = true

        // Notes stack: one NoteBlockView per loaded note ref (dynamic, cleared on each configure).
        notesStack.orientation = .vertical
        notesStack.alignment = .leading
        notesStack.spacing = 12
        notesStack.translatesAutoresizingMaskIntoConstraints = false
        notesStack.isHidden = true

        // Footer: hairline divider, then a small row — files left, +adds/−dels right.
        statsDivider.boxType = .separator
        statsDivider.translatesAutoresizingMaskIntoConstraints = false

        filesLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        filesLabel.textColor = .tertiaryLabelColor
        statsLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        statsLabel.alignment = .right

        statsRow.orientation = .horizontal
        statsRow.alignment = .firstBaseline
        statsRow.spacing = 8
        statsRow.translatesAutoresizingMaskIntoConstraints = false
        statsRow.addArrangedSubview(filesLabel)
        let statsSpacer = NSView()
        statsSpacer.translatesAutoresizingMaskIntoConstraints = false
        statsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statsRow.addArrangedSubview(statsSpacer)
        statsRow.addArrangedSubview(statsLabel)

        // Vertical stack: subject → identity → body → chips → notes. Footer pins below.
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (view, name) in zip(
            [subjectLabel, identityRow, bodyLabel, chipRow, notesStack],
            ["subject", "identity", "body", "chips", "notes"]
        ) {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor)
                .id("CommitSummary.\(name).fillWidth")
                .isActive = true
        }
        // Rhythm: subject and identity sit close; body breathes; chips and notes breathe more.
        stack.setCustomSpacing(10, after: subjectLabel)
        stack.setCustomSpacing(16, after: identityRow)
        stack.setCustomSpacing(12, after: bodyLabel)
        stack.setCustomSpacing(12, after: chipRow)

        addSubview(stack)
        addSubview(statsDivider)
        addSubview(statsRow)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.topInset)
                .id("CommitSummary.stack.top"),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hInset)
                .id("CommitSummary.stack.leading"),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hInset)
                .id("CommitSummary.stack.trailing"),

            statsDivider.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: Self.bottomInset + 2)
                .id("CommitSummary.statsDivider.top"),
            statsDivider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hInset)
                .id("CommitSummary.statsDivider.leading"),
            statsDivider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hInset)
                .id("CommitSummary.statsDivider.trailing"),

            statsRow.topAnchor.constraint(equalTo: statsDivider.bottomAnchor, constant: 8)
                .id("CommitSummary.statsRow.top"),
            statsRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hInset)
                .id("CommitSummary.statsRow.leading"),
            statsRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hInset)
                .id("CommitSummary.statsRow.trailing"),
            statsRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomInset)
                .id("CommitSummary.statsRow.bottom"),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Multiline labels need an explicit wrapping width to compute their height.
        let bodyWidth = bounds.width - Self.hInset * 2
        subjectLabel.preferredMaxLayoutWidth = bodyWidth
        bodyLabel.preferredMaxLayoutWidth = bodyWidth
        // Propagate width to each note block so its body label wraps correctly.
        for case let block as NoteBlockView in notesStack.arrangedSubviews {
            block.preferredBodyWidth = bodyWidth
        }
    }

    // MARK: Attributed-string helpers — used so multi-line subject/body get proper line-height.

    private static func paragraph(lineHeightMultiple: CGFloat,
                                  lineBreak: NSLineBreakMode) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineHeightMultiple
        // Word-wrap on prose so multi-line bodies actually wrap instead of truncating on line 1;
        // the field's maximumNumberOfLines still caps total height.
        p.lineBreakMode = lineBreak
        return p
    }

    private static func styled(_ text: String, font: NSFont, color: NSColor,
                               lineHeightMultiple: CGFloat,
                               lineBreak: NSLineBreakMode = .byWordWrapping) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph(lineHeightMultiple: lineHeightMultiple, lineBreak: lineBreak),
        ])
    }

    @objc private func toggleCollapse() {
        isCollapsed.toggle()
        updateCollapseButton()
        // Let the parent prep (e.g. reset its scroll position) before we drive the layout pass.
        onCollapseToggle?()
        // Pre-set the wrapping width so the label measures its intrinsic height at the correct
        // width when maximumNumberOfLines changes — before the constraint engine runs. Without
        // this the subject snaps to its new line count with a stale (or zero) wrap width and
        // then jumps again once layout() sets the real width.
        let bodyWidth = bounds.width - Self.hInset * 2
        if bodyWidth > 0 {
            subjectLabel.preferredMaxLayoutWidth = bodyWidth
            bodyLabel.preferredMaxLayoutWidth = bodyWidth
        }
        // Single animated layout pass: flipping visibility on `bodyLabel`/`notesStack` and
        // changing `subjectLabel.maximumNumberOfLines` mutates the intrinsic content height,
        // and the constraint chain (vStack → divider → statsRow) carries that change all the
        // way up. `allowsImplicitAnimation` makes the resulting frame deltas animate.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            applyCollapseState()
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func updateCollapseButton() {
        let name = isCollapsed ? "chevron.down" : "chevron.up"
        collapseButton.image = NSImage(systemSymbolName: name,
                                       accessibilityDescription: isCollapsed ? "Expand" : "Collapse")
    }

    fileprivate func applyCollapseState() {
        let hasBody = !bodyLabel.attributedStringValue.string.isEmpty
        bodyLabel.isHidden = isCollapsed || !hasBody
        notesStack.isHidden = isCollapsed || notesStack.arrangedSubviews.isEmpty
        // Chips stay visible in both states — they're the compact metadata summary.
        // Subject stays visible (truncated to 1 line when collapsed).
        subjectLabel.maximumNumberOfLines = isCollapsed ? 1 : 3
        // Don't call needsLayout here: when toggling, the animation block drives the single
        // layout pass via layoutSubtreeIfNeeded(). A competing needsLayout schedules a
        // non-animated pass that fires before the animation context, causing the jump.
    }

    func setStats(_ text: String) {
        // Caller hands us "12 FILES   +234  −56" or "CHANGES".
        // We split on the 3-space gap that the formatter uses; left side is the file count,
        // right side gets +/− tokens colored.
        let parts = text.components(separatedBy: "   ")
        if parts.count >= 2 {
            filesLabel.stringValue = parts[0]
            statsLabel.attributedStringValue = Self.coloredStats(parts.dropFirst().joined(separator: " "))
        } else {
            filesLabel.stringValue = text
            statsLabel.attributedStringValue = NSAttributedString()
        }
    }

    private static func coloredStats(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        for token in text.split(separator: " ").map(String.init) {
            if result.length > 0 { result.append(NSAttributedString(string: "  ")) }
            let color: NSColor
            if token.hasPrefix("+") { color = Theme.Color.addStat }
            else if token.hasPrefix("−") || token.hasPrefix("-") { color = Theme.Color.delStat }
            else { color = .tertiaryLabelColor }
            result.append(NSAttributedString(string: token, attributes: [
                .font: font, .foregroundColor: color,
            ]))
        }
        return result
    }

    func configure(header: DetailHeader) {
        switch header {
        case .none:
            subjectLabel.isHidden = true
            identityRow.isHidden = true
            bodyLabel.isHidden = true
            chipRow.isHidden = true
            notesStack.isHidden = true
        case .commit(let commit, let notes, let aiAuthorship):
            configureCommit(commit, notes: notes, aiAuthorship: aiAuthorship)
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
        subjectLabel.attributedStringValue = Self.styled(
            "Uncommitted Changes", font: Self.subjectFont,
            color: .labelColor, lineHeightMultiple: Self.subjectLineMultiple)

        identityRow.isHidden = false
        authorDot.isHidden = true
        if let branch {
            authorLabel.stringValue = "⎇  \(branch)"
            authorLabel.isHidden = false
        } else {
            authorLabel.isHidden = true
        }
        var tally: [String] = ["\(staged) staged", "\(unstaged) unstaged"]
        if untracked > 0 { tally.append("\(untracked) untracked") }
        dateLabel.stringValue = tally.joined(separator: " · ")
        shaPill.isHidden = true

        let draft = (prepared ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty {
            bodyLabel.isHidden = true
            bodyLabel.toolTip = nil
        } else {
            bodyLabel.isHidden = false
            bodyLabel.attributedStringValue = Self.styled(
                draft, font: Self.bodyFont, color: .labelColor,
                lineHeightMultiple: Self.bodyLineMultiple)
            bodyLabel.toolTip = draft
        }

        collapseButton.isHidden = true
        chipRow.isHidden = true
        notesStack.isHidden = true
        needsLayout = true
    }

    private func configureCommit(_ commit: Commit?,
                                  notes: [CommitDetailPresenter.NoteEntry],
                                  aiAuthorship: AIAuthorshipRecord?) {
        isCollapsed = false
        updateCollapseButton()
        guard let commit else {
            subjectLabel.isHidden = true
            identityRow.isHidden = true
            bodyLabel.isHidden = true
            collapseButton.isHidden = true
            chipRow.isHidden = true
            notesStack.isHidden = true
            return
        }
        collapseButton.isHidden = false
        subjectLabel.isHidden = false
        identityRow.isHidden = false

        if commit.subject.isEmpty {
            subjectLabel.attributedStringValue = Self.styled(
                "(no commit message)", font: Self.subjectFont,
                color: .tertiaryLabelColor, lineHeightMultiple: Self.subjectLineMultiple)
        } else {
            subjectLabel.attributedStringValue = Self.styled(
                commit.subject, font: Self.subjectFont,
                color: .labelColor, lineHeightMultiple: Self.subjectLineMultiple)
        }

        authorDot.isHidden = false
        authorDot.tint = Self.authorTint(for: commit.author.name)
        authorLabel.isHidden = false
        authorLabel.stringValue = commit.author.name
        dateLabel.stringValue = RelativeDate.short(commit.authorDate)
        dateLabel.toolTip = RelativeDate.exact(commit.authorDate)
        shaPill.isHidden = false
        shaPill.text = String(commit.sha.prefix(7))
        shaPill.toolTip = commit.sha

        // Show prose body without trailer lines (trailers appear in chips below).
        // Always update the attributed string so switching commits while collapsed
        // doesn't show stale content when the user later expands.
        let prose = commit.bodyWithoutTrailers
        if prose.isEmpty {
            bodyLabel.attributedStringValue = NSAttributedString()
            bodyLabel.toolTip = nil
        } else {
            bodyLabel.attributedStringValue = Self.styled(
                prose, font: Self.bodyFont, color: .labelColor,
                lineHeightMultiple: Self.bodyLineMultiple)
            bodyLabel.toolTip = prose
        }
        bodyLabel.isHidden = prose.isEmpty || isCollapsed

        // Subject shows up to 3 lines expanded, 1 line collapsed.
        subjectLabel.maximumNumberOfLines = isCollapsed ? 1 : 3

        // Chips: conventional commit type/scope/breaking + key trailers + issue refs + AI authorship.
        rebuildChips(for: commit, aiAuthorship: aiAuthorship)

        // Notes: one block per loaded note ref (hidden when collapsed).
        rebuildNotes(notes)

        needsLayout = true
    }

    private func clearStack(_ stack: NSStackView) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    }

    private func rebuildChips(for commit: Commit, aiAuthorship: AIAuthorshipRecord?) {
        clearStack(chipRow)

        // Conventional commit type + scope + breaking flag.
        if let conv = commit.conventional {
            chipRow.addArrangedSubview(
                BadgeLabel(text: conv.type, tint: Self.typeColor(conv.type),
                           font: Theme.Font.pill, filled: true))
            if let scope = conv.scope, !scope.isEmpty {
                chipRow.addArrangedSubview(
                    BadgeLabel(text: scope, tint: .systemGray, font: Theme.Font.pill, filled: false))
            }
            if conv.isBreaking {
                chipRow.addArrangedSubview(
                    BadgeLabel(text: "breaking", tint: .systemRed, font: Theme.Font.pill, filled: false))
            }
        }

        // Key trailers: reviewers, co-authors, issue links.
        for trailer in commit.trailers where Self.isDisplayTrailer(trailer.key) {
            let text = Self.trailerChipText(trailer)
            chipRow.addArrangedSubview(
                BadgeLabel(text: text, tint: .systemGray, font: Theme.Font.pill, filled: false))
        }

        // Issue refs not already expressed by a trailer chip (avoids showing #123 twice when
        // "Fixes: #123" is already shown as a trailer).
        let trailerValues = commit.trailers.map(\.value)
        for ref in commit.issueRefs
            where !trailerValues.contains(where: { $0.contains(ref.raw) }) {
            chipRow.addArrangedSubview(
                BadgeLabel(text: ref.raw, tint: .systemBlue, font: Theme.Font.pill, filled: false))
        }

        // AI authorship chip: summarise which agents contributed lines to this commit.
        if let aiAuthorship {
            let totals = aiAuthorship.authorTotals
            if !totals.isEmpty {
                let agents = totals.sorted { $0.value > $1.value }
                    .prefix(2).map(\.key).joined(separator: " · ")
                let label = "✦ \(agents)"
                chipRow.addArrangedSubview(
                    BadgeLabel(text: label, tint: .systemPurple, font: Theme.Font.pill, filled: false))
            }
        }

        chipRow.isHidden = chipRow.arrangedSubviews.isEmpty
    }

    private func rebuildNotes(_ notes: [CommitDetailPresenter.NoteEntry]) {
        clearStack(notesStack)
        for entry in notes {
            let block = NoteBlockView(caption: entry.name.uppercased(), body: entry.text)
            notesStack.addArrangedSubview(block)
            block.widthAnchor.constraint(equalTo: notesStack.widthAnchor)
                .id("CommitSummary.noteBlock.\(entry.name).width").isActive = true
        }
        notesStack.isHidden = notes.isEmpty || isCollapsed
    }

    private static func isDisplayTrailer(_ key: String) -> Bool {
        switch key.lowercased() {
        case "reviewed-by", "co-authored-by", "co-author",
             "fixes", "closes", "resolves", "refs": return true
        default: return false
        }
    }

    private static func trailerChipText(_ trailer: CommitTrailer) -> String {
        // Strip email from identity values: "Alice <alice@example.com>" → "Alice".
        let valueDisplay = trailer.value.replacingOccurrences(
            of: #"\s*<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "\(trailer.key): \(valueDisplay)"
    }

    private static func typeColor(_ type: String) -> NSColor {
        switch type {
        case "feat": return .systemBlue
        case "fix":  return .systemOrange
        case "docs": return .systemTeal
        case "test": return .systemGreen
        case "perf": return .systemPurple
        case "refactor": return .systemIndigo
        default:     return .systemGray
        }
    }

    /// Deterministic color per author so the same person always gets the same dot —
    /// gives quick visual identity in long timelines without needing fetched avatars.
    private static let authorPalette: [NSColor] = [
        .systemBlue, .systemPurple, .systemTeal, .systemPink,
        .systemIndigo, .systemGreen, .systemOrange, .systemRed,
    ]
    private static func authorTint(for name: String) -> NSColor {
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return authorPalette[abs(hash) % authorPalette.count]
    }
}

/// Small colored dot next to the author name — visual identity for the commit's author.
private final class AuthorDot: NSView {
    var tint: NSColor = .systemBlue {
        didSet { layer?.backgroundColor = tint.withAlphaComponent(0.9).cgColor }
    }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4.5
        layer?.backgroundColor = tint.withAlphaComponent(0.9).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 9).id("AuthorDot.width"),
            heightAnchor.constraint(equalToConstant: 9).id("AuthorDot.height"),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Monospaced 7-char SHA in a subtle pill. Borderless fill so it reads as a tag, not a button.
private final class ShaPill: NSView {
    private let label = NSTextField(labelWithString: "")
    var text: String = "" {
        didSet {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.2,
            ])
            invalidateIntrinsicContentSize()
        }
    }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.tertiaryLabelColor
            .withAlphaComponent(0.10).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7)
                .id("ShaPill.label.leading"),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7)
                .id("ShaPill.label.trailing"),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2)
                .id("ShaPill.label.top"),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
                .id("ShaPill.label.bottom"),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Note block view

/// An editorial annotation block: a colored left bar, a small caption ("NOTE", "REVIEW", …),
/// and the note body text. Used by CommitSummaryView to display one note per ref.
@objc(NoteBlockView)
private final class NoteBlockView: NSView {
    private let bar = NSView()
    private let caption = NSTextField(labelWithString: "")
    private let body = NSTextField(labelWithString: "")

    var preferredBodyWidth: CGFloat = 0 {
        didSet { body.preferredMaxLayoutWidth = max(0, preferredBodyWidth - 15) }
    }

    init(caption: String, body bodyText: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.65).cgColor
        bar.layer?.cornerRadius = 1.5
        bar.translatesAutoresizingMaskIntoConstraints = false

        self.caption.attributedStringValue = NSAttributedString(
            string: caption,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 1.2,
            ])
        self.caption.translatesAutoresizingMaskIntoConstraints = false

        self.body.font = .systemFont(ofSize: 13, weight: .regular)
        self.body.textColor = .labelColor
        self.body.maximumNumberOfLines = 0
        self.body.lineBreakMode = .byWordWrapping
        self.body.cell?.wraps = true
        self.body.cell?.isScrollable = false
        self.body.stringValue = bodyText
        self.body.toolTip = bodyText
        self.body.translatesAutoresizingMaskIntoConstraints = false

        addSubview(bar)
        addSubview(self.caption)
        addSubview(self.body)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor)
                .id("NoteBlockView.bar.leading"),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 2)
                .id("NoteBlockView.bar.top"),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
                .id("NoteBlockView.bar.bottom"),
            bar.widthAnchor.constraint(equalToConstant: 3)
                .id("NoteBlockView.bar.width"),

            self.caption.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 12)
                .id("NoteBlockView.caption.leading"),
            self.caption.topAnchor.constraint(equalTo: topAnchor)
                .id("NoteBlockView.caption.top"),
            self.caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
                .id("NoteBlockView.caption.trailing"),

            self.body.leadingAnchor.constraint(equalTo: self.caption.leadingAnchor)
                .id("NoteBlockView.body.leading"),
            self.body.topAnchor.constraint(equalTo: self.caption.bottomAnchor, constant: 4)
                .id("NoteBlockView.body.top"),
            self.body.trailingAnchor.constraint(equalTo: trailingAnchor)
                .id("NoteBlockView.body.trailing"),
            self.body.bottomAnchor.constraint(equalTo: bottomAnchor)
                .id("NoteBlockView.body.bottom"),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Outline view with context menu support

@objc(FilesOutlineView)
private final class FilesOutlineView: NSOutlineView {
    var onContextMenu: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        return onContextMenu?(row)
    }
}

// MARK: - File filter model

/// Status/type filter for the file list, driven by the funnel control. Empty facet sets mean
/// "all"; a file must satisfy every *active* facet to remain visible.
private struct FileFilter: Equatable {
    var statuses: Set<DiffStatusKind> = []
    var signals: Set<FileSignal> = []
    var hideNoise = false

    var isActive: Bool { !statuses.isEmpty || !signals.isEmpty || hideNoise }

    func matches(_ fa: FileAnalysis) -> Bool {
        if hideNoise && fa.isNoise { return false }
        if !statuses.isEmpty && !statuses.contains(fa.statusKind) { return false }
        if !signals.isEmpty && Set(fa.signals).isDisjoint(with: signals) { return false }
        return true
    }
}
