import AppKit
import Presenters

// MARK: - Delegate

@MainActor
protocol CommitListViewControllerDelegate: AnyObject {
    /// User selected a commit (SHA) in the list.
    func commitListViewController(_ vc: CommitListViewController, didSelectSHA sha: String?)
    /// User clicked the Refresh button in the dirty banner.
    func commitListViewControllerDidRequestRefresh(_ vc: CommitListViewController)
}

// MARK: - View controller

/// Commit-list pane: an NSTableView bound to `TimelinePresenter`.
/// Columns: graph (placeholder), author, date, subject.
/// Includes a non-modal dirty-banner strip that appears when `presenter.isDirty`.
final class CommitListViewController: NSViewController, PresenterObserving {
    weak var delegate: CommitListViewControllerDelegate?

    // Injected by the coordinator when a repo is selected.
    var presenter: TimelinePresenter? {
        didSet {
            oldValue?.observer = nil
            presenter?.observer = self
            reloadFromPresenter()
        }
    }

    // MARK: UI elements

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /// Non-modal strip shown when `presenter.isDirty`.
    private let dirtyBanner = DirtyBannerView()

    private let stackView = NSStackView()

    // MARK: - Formatters

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // MARK: - Lifecycle

    override func loadView() {
        // --- Table columns ---
        let graphCol = makeColumn("graph", title: "", width: 60)
        let authorCol = makeColumn("author", title: "Author", width: 120)
        let dateCol = makeColumn("date", title: "Date", width: 90)
        let subjectCol = makeColumn("subject", title: "Subject", width: 400)

        for col in [graphCol, authorCol, dateCol, subjectCol] {
            tableView.addTableColumn(col)
        }
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 20
        tableView.focusRingType = .none
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // --- Stack: banner on top, table below ---
        stackView.orientation = .vertical
        stackView.spacing = 0
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false

        dirtyBanner.refreshButton.target = self
        dirtyBanner.refreshButton.action = #selector(refreshTapped)
        dirtyBanner.isHidden = true

        stackView.addArrangedSubview(dirtyBanner)
        stackView.addArrangedSubview(scrollView)
        stackView.setCustomSpacing(0, after: dirtyBanner)

        // Make scrollView fill the remaining space
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let container = NSView()
        container.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: container.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    // MARK: - Actions

    @objc private func refreshTapped() {
        delegate?.commitListViewControllerDidRequestRefresh(self)
    }

    // MARK: - PresenterObserving

    func presenterDidUpdate(_ presenter: AnyObject) {
        reloadFromPresenter()
    }

    private func reloadFromPresenter() {
        tableView.reloadData()
        dirtyBanner.isHidden = !(presenter?.isDirty ?? false)

        // Sync selection
        if let sha = presenter?.selectedSHA,
           let idx = presenter?.commits.firstIndex(where: { $0.sha == sha }) {
            let row = idx
            if tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                tableView.scrollRowToVisible(row)
            }
        }
    }

    // MARK: - Column helper

    private func makeColumn(_ id: String, title: String, width: CGFloat) -> NSTableColumn {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.title = title
        col.width = width
        col.minWidth = 40
        return col
    }
}

// MARK: - NSTableViewDataSource

extension CommitListViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        presenter?.commits.count ?? 0
    }
}

// MARK: - NSTableViewDelegate

extension CommitListViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let commits = presenter?.commits, row < commits.count,
              let colID = tableColumn?.identifier.rawValue else { return nil }
        let commit = commits[row]

        let cellID = NSUserInterfaceItemIdentifier("Cell-\(colID)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            tf.font = colID == "subject" ? NSFont.systemFont(ofSize: 12) : NSFont.systemFont(ofSize: 11)
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        switch colID {
        case "graph":
            // Graph lane placeholder — will be a custom cell in a later phase.
            cell.textField?.stringValue = commit.isMerge ? "⑂" : "●"
            cell.textField?.alignment = .center
        case "author":
            cell.textField?.stringValue = commit.author.name
        case "date":
            cell.textField?.stringValue = Self.dateFormatter.string(from: commit.authorDate)
        case "subject":
            cell.textField?.stringValue = commit.subject
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard let commits = presenter?.commits else {
            delegate?.commitListViewController(self, didSelectSHA: nil)
            return
        }
        let sha = row >= 0 && row < commits.count ? commits[row].sha : nil
        delegate?.commitListViewController(self, didSelectSHA: sha)
    }
}

// MARK: - Dirty banner

/// Non-modal strip shown at the top of the commit list when git data changed on disk.
final class DirtyBannerView: NSView {
    let refreshButton: NSButton

    override init(frame: NSRect) {
        self.refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        self.refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15).cgColor

        let label = NSTextField(labelWithString: "Repository changed on disk.")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        refreshButton.bezelStyle = .inline
        refreshButton.font = NSFont.systemFont(ofSize: 11)

        let stack = NSStackView(views: [label, refreshButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }
}
