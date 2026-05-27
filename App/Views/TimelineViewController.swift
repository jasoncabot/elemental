import AppKit
import GitData
import Presenters

@MainActor
protocol TimelineViewControllerDelegate: AnyObject {
    func timelineViewController(_ vc: TimelineViewController, didSelectSHA sha: String?)
    func timelineViewControllerDidRequestRefresh(_ vc: TimelineViewController)
}

/// The left column: a readable review timeline rather than a git-log table.
/// Each commit leads with its subject (intent), with recency/author as quiet
/// secondary metadata and ref pills for orientation. Exact SHA/timestamp are
/// surfaced on hover via tooltip, keeping the skim view uncluttered.
final class TimelineViewController: NSViewController, PresenterObserving {
    weak var delegate: TimelineViewControllerDelegate?

    var presenter: TimelinePresenter? {
        didSet {
            oldValue?.removeObserver(self)
            presenter?.addObserver(self)
            reloadFromPresenter()
        }
    }

    private let tableView = TimelineTableView()
    private let scrollView = NSScrollView()
    private let dirtyBanner = DirtyBannerView()
    private let emptyLabel = NSTextField(labelWithString: "Drop a repository folder here")
    private var isUpdatingSelection = false
    /// Identity of the currently-rendered commit set, so selection changes don't force a full reload.
    private var renderedToken: String?
    private var bannerHeight: NSLayoutConstraint!

    // MARK: - Lifecycle

    override func loadView() {
        let col = NSTableColumn(identifier: .init("commit"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = Theme.Metric.timelineRowHeight
        tableView.focusRingType = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onNavigate = { [weak self] delta in self?.move(by: delta) }

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = true

        dirtyBanner.refreshButton.target = self
        dirtyBanner.refreshButton.action = #selector(refreshTapped)
        dirtyBanner.isHidden = true

        emptyLabel.font = Theme.Font.secondary
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState

        dirtyBanner.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(dirtyBanner)
        container.addSubview(emptyLabel)

        bannerHeight = dirtyBanner.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            dirtyBanner.topAnchor.constraint(equalTo: container.topAnchor),
            dirtyBanner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dirtyBanner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bannerHeight,

            scrollView.topAnchor.constraint(equalTo: dirtyBanner.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        view = container
    }

    // MARK: - Actions

    @objc private func refreshTapped() {
        delegate?.timelineViewControllerDidRequestRefresh(self)
    }

    private func move(by delta: Int) {
        guard let commits = presenter?.commits, !commits.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), commits.count - 1)
        guard next != current else { return }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: - PresenterObserving

    func presenterDidUpdate(_ presenter: AnyObject) { reloadFromPresenter() }

    private func reloadFromPresenter() {
        let commits = presenter?.commits ?? []
        emptyLabel.isHidden = !commits.isEmpty
        let dirty = presenter?.isDirty ?? false
        dirtyBanner.isHidden = !dirty
        bannerHeight.constant = dirty ? 30 : 0

        // Only rebuild rows when the commit set itself changed — a bare selection
        // change must feel instant and shouldn't churn every cell.
        let token = "\(commits.count)|\(commits.first?.sha ?? "")|\(commits.last?.sha ?? "")"
        if token != renderedToken {
            renderedToken = token
            tableView.reloadData()
        }

        if let sha = presenter?.selectedSHA,
           let idx = commits.firstIndex(where: { $0.sha == sha }) {
            if tableView.selectedRow != idx {
                isUpdatingSelection = true
                tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                tableView.scrollRowToVisible(idx)
                isUpdatingSelection = false
            }
        }
    }

    /// Rows with ref pills need extra vertical room; plain commits stay compact.
    private func hasPills(_ commit: Commit) -> Bool {
        commit.refNames.contains { name in
            let n = name.trimmingCharacters(in: .whitespaces)
            return !n.isEmpty && n != "HEAD"
        }
    }
}

// MARK: - Data / delegate

extension TimelineViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { presenter?.commits.count ?? 0 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let commits = presenter?.commits, row < commits.count else { return 48 }
        return hasPills(commits[row]) ? 76 : 48
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TimelineRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let commits = presenter?.commits, row < commits.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("TimelineCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? TimelineCellView)
            ?? TimelineCellView(identifier: id)
        cell.configure(with: commits[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection else { return }
        let row = tableView.selectedRow
        let commits = presenter?.commits ?? []
        let sha = (row >= 0 && row < commits.count) ? commits[row].sha : nil
        delegate?.timelineViewController(self, didSelectSHA: sha)
    }
}

// MARK: - Timeline table (keyboard nav)

private final class TimelineTableView: NSTableView {
    var onNavigate: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "j": onNavigate?(1); return
        case "k": onNavigate?(-1); return
        default: break
        }
        super.keyDown(with: event)
    }
}

// MARK: - Row view (rounded selection)

private final class TimelineRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let inset = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: Theme.Metric.cornerRadius, yRadius: Theme.Metric.cornerRadius)
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
        path.fill()
    }
}

// MARK: - Cell view

private final class TimelineCellView: NSTableCellView {
    private let subjectLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let pillStack = NSStackView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        subjectLabel.font = Theme.Font.subject()
        subjectLabel.textColor = .labelColor
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.maximumNumberOfLines = 1
        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metaLabel.font = Theme.Font.secondary
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        pillStack.orientation = .horizontal
        pillStack.spacing = 4
        pillStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(subjectLabel)
        addSubview(metaLabel)
        addSubview(pillStack)

        NSLayoutConstraint.activate([
            subjectLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            subjectLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subjectLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            metaLabel.leadingAnchor.constraint(equalTo: subjectLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: subjectLabel.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: 3),

            pillStack.leadingAnchor.constraint(equalTo: subjectLabel.leadingAnchor),
            pillStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            pillStack.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with commit: Commit) {
        subjectLabel.stringValue = commit.subject.isEmpty ? "(no subject)" : commit.subject
        let mergeTag = commit.isMerge ? "merge · " : ""
        metaLabel.stringValue = "\(mergeTag)\(RelativeDate.short(commit.authorDate)) · \(commit.author.name)"

        toolTip = "\(commit.sha.prefix(10))\n\(commit.author.name) <\(commit.author.email)>\n\(RelativeDate.exact(commit.authorDate))"

        pillStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for ref in refPills(commit.refNames).prefix(3) {
            pillStack.addArrangedSubview(BadgeLabel(text: ref.text, tint: ref.tint))
        }
        pillStack.isHidden = pillStack.arrangedSubviews.isEmpty
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
}

// MARK: - Dirty banner

/// Non-modal strip shown when git data changed on disk; never auto-reloads.
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
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
