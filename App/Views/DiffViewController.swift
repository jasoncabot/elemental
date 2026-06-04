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
    private let floatingHunkHeader = FloatingHunkHeaderView()
    /// Draggable divider between the two halves of the side-by-side view. Hidden in unified mode.
    private let sideDividerHandle = SideBySideDividerView()
    private var sideDividerLeading: NSLayoutConstraint!
    /// Split point as a fraction of the viewport width; shared by every side-by-side row.
    private var sideSplitFraction: CGFloat = 0.5

    private var hunkSections: [HunkSectionView] = []
    /// Shown in place of hunk sections for noise-collapsed or binary files.
    private var noticeView: NSView?
    /// Coordinates selection across all hunk content views — clears siblings when a new
    /// selection begins and extends selections across hunk boundaries during a drag.
    private let selectionCoordinator = DiffSelectionCoordinator()
    /// The stacking constraints that pin sections top-to-bottom inside outerContent.
    /// Deactivated and replaced on every rebuild to avoid duplicates.
    private var sectionStackConstraints: [NSLayoutConstraint] = []

    private var currentSelection: DetailSelection?
    private var currentFile: DiffFile?
    private var sideBySide = false
    private var sizeAtGestureStart: CGFloat = Theme.Font.defaultDiffSize
    private var collapsedHunks: Set<Int> = []
    private var noiseExpanded = false
    private var focusChanges = false

    /// The hunk index the sticky overlay currently stands in for, so a click on it collapses
    /// the right hunk. nil whenever the overlay is hidden.
    private var floatingHunkIndex: Int?

    private var imageFetchTask: Task<Void, Never>?
    /// The `DiffFile.id` of the binary image currently shown in `noticeView`.
    /// Guards against re-fetching when unrelated presenter updates fire.
    private var currentImagePreviewID: DiffFile.ID?

    /// Extensions rendered via macOS ImageIO — no custom parsing, no script execution.
    /// SVG is rendered by Apple's static CGSVGDocument renderer (no JS, no foreignObject).
    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "webp", "svg"]

    private static func isImageFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeDidChange),
                                               name: .diffFontSizeDidChange, object: nil)
        outerScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollDidChange),
                                               name: NSView.boundsDidChangeNotification,
                                               object: outerScroll.contentView)
    }

    @objc private func fontSizeDidChange() { reload() }

    @objc private func scrollDidChange(_ note: Notification) { updateFloatingHeader() }

    private func updateFloatingHeader() {
        guard !hunkSections.isEmpty else {
            floatingHunkIndex = nil
            floatingHunkHeader.isHidden = true
            return
        }
        let scrollTop = outerScroll.contentView.bounds.origin.y
        let headerH = Theme.Metric.hunkHeaderHeight
        // Show the sticky label for the section whose own header has fully scrolled off
        // the top but whose body lines are still in the viewport. A collapsed hunk is only
        // `headerH` tall, so it can never satisfy both bounds — the overlay always represents
        // an expanded hunk, which is why its chevron is always "open".
        var candidate: HunkSectionView? = nil
        for section in hunkSections {
            let top = section.frame.minY
            if top + headerH < scrollTop && section.frame.maxY > scrollTop {
                candidate = section
            }
        }
        if let s = candidate {
            floatingHunkIndex = s.hunkIndex
            floatingHunkHeader.configure("▾ " + s.headerText)
            floatingHunkHeader.isHidden = false
        } else {
            floatingHunkIndex = nil
            floatingHunkHeader.isHidden = true
        }
    }

    @objc private func handleMagnify(_ gr: NSMagnificationGestureRecognizer) {
        if gr.state == .began { sizeAtGestureStart = Theme.Font.diffFontSize }
        let range = Theme.Font.maxDiffSize - Theme.Font.minDiffSize
        Theme.Font.diffFontSize = sizeAtGestureStart + gr.magnification * range * 0.4
    }

    override func loadView() {
        outerContent.translatesAutoresizingMaskIntoConstraints = false
        outerContent.addGestureRecognizer(
            NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
        )

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
        header.onToggleContext = { [weak self] in
            guard let self, let source = self.source else { return }
            source.setDiffContext(source.diffContext == .wholeFile ? .standard : .wholeFile)
        }

        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        outerScroll.translatesAutoresizingMaskIntoConstraints = false
        floatingHunkHeader.translatesAutoresizingMaskIntoConstraints = false
        floatingHunkHeader.isHidden = true
        // Clicking the sticky overlay collapses the hunk it stands in for, mirroring its inline
        // header. Collapsing removes that hunk's body, so re-evaluate which header should float.
        floatingHunkHeader.onToggle = { [weak self] in
            guard let self, let index = self.floatingHunkIndex else { return }
            self.toggleHunk(index)
            self.outerContent.layoutSubtreeIfNeeded()
            self.updateFloatingHeader()
        }
        sideDividerHandle.translatesAutoresizingMaskIntoConstraints = false
        sideDividerHandle.isHidden = true
        sideDividerHandle.onDragToX = { [weak self] x in self?.dragSideDivider(toContainerX: x) }
        container.addSubview(header)
        container.addSubview(outerScroll)
        container.addSubview(sideDividerHandle)
        container.addSubview(emptyLabel)
        container.addSubview(floatingHunkHeader)

        sideDividerLeading = sideDividerHandle.leadingAnchor.constraint(
            equalTo: container.leadingAnchor).id("DiffView.sideDivider.leading")

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

            floatingHunkHeader.topAnchor.constraint(equalTo: outerScroll.topAnchor)
                .id("DiffView.floatingHunkHeader.top"),
            floatingHunkHeader.leadingAnchor.constraint(equalTo: outerScroll.leadingAnchor)
                .id("DiffView.floatingHunkHeader.leading"),
            floatingHunkHeader.trailingAnchor.constraint(equalTo: outerScroll.trailingAnchor)
                .id("DiffView.floatingHunkHeader.trailing"),
            floatingHunkHeader.heightAnchor.constraint(equalToConstant: Theme.Metric.hunkHeaderHeight)
                .id("DiffView.floatingHunkHeader.height"),

            sideDividerLeading,
            sideDividerHandle.topAnchor.constraint(equalTo: outerScroll.topAnchor)
                .id("DiffView.sideDivider.top"),
            sideDividerHandle.bottomAnchor.constraint(equalTo: outerScroll.bottomAnchor)
                .id("DiffView.sideDivider.bottom"),
            sideDividerHandle.widthAnchor.constraint(equalToConstant: SideBySideDividerView.width)
                .id("DiffView.sideDivider.width"),
        ])

        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateAllContentColumnWidths()
        repositionSideDivider()
    }

    // MARK: - Side-by-side divider

    /// Keeps the divider handle at `sideSplitFraction` of the viewport width.
    private func repositionSideDivider() {
        let w = outerScroll.bounds.width
        guard w > 0 else { return }
        sideDividerLeading.constant = sideSplitFraction * w - SideBySideDividerView.width / 2
    }

    /// Live drag: convert the handle's x (in the diff container) to a fraction and re-balance.
    private func dragSideDivider(toContainerX x: CGFloat) {
        let w = outerScroll.bounds.width
        guard w > 0 else { return }
        let frac = min(0.8, max(0.2, x / w))
        guard abs(frac - sideSplitFraction) > 0.001 else { return }
        sideSplitFraction = frac
        repositionSideDivider()
        for section in hunkSections { section.applySplitFraction(frac) }
    }

    private func updateSideDividerVisibility() {
        let show = sideBySide && !hunkSections.isEmpty
        sideDividerHandle.isHidden = !show
        if show { repositionSideDivider() }
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
        header.setWholeFile(source?.diffContext == .wholeFile)
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
            if Self.isImageFile(file.displayPath) {
                showImagePreview(for: file)
            } else {
                showNotice(signal: "binary", lines: 0)
            }
            return
        }

        let churnLines = file.hunks.reduce(0) { sum, hunk in
            sum + hunk.lines.filter { $0.kind != .context && $0.change != .substantive }.count
        }
        header.setFocus(focusChanges, churnLines: churnLines)

        // Remove notice (or image preview) if present.
        imageFetchTask?.cancel(); imageFetchTask = nil
        currentImagePreviewID = nil
        noticeView?.removeFromSuperview()
        noticeView = nil

        // Build rows per hunk.
        let gw = Self.gutterWidth(for: file)
        var newSections: [HunkSectionView] = []
        for (i, hunk) in file.hunks.enumerated() {
            // Focus mode hides whitespace/moved lines to surface substantive edits.
            // Skip it for pure deletions (no additions): there is nothing to focus towards
            // and the filter would strip lines the user needs to see what was removed.
            let applyFocus = focusChanges && file.additions > 0
            let visible = applyFocus
                ? hunk.lines.filter { $0.kind == .context || $0.change == .substantive }
                : hunk.lines
            let rows: [HunkRow] = sideBySide
                ? Self.pair(visible).map { .pair(left: $0, right: $1) }
                : visible.map { .line($0) }

            let contentMinWidth = computeContentMinWidth(rows)
            let section = reuseOrMake(index: i,
                                      text: hunk.context ?? hunk.header,
                                      rows: rows,
                                      contentMinWidth: contentMinWidth,
                                      gutterWidth: gw)
            section.isCollapsed = collapsedHunks.contains(i)
            newSections.append(section)
        }

        installSections(newSections)
        updateAllContentColumnWidths()
        updateFloatingHeader()
        updateSideDividerVisibility()
    }

    // MARK: - Section management

    private func clearSections() {
        imageFetchTask?.cancel()
        imageFetchTask = nil
        currentImagePreviewID = nil
        hunkSections.forEach { $0.removeFromSuperview() }
        hunkSections = []
        selectionCoordinator.views = []
        NSLayoutConstraint.deactivate(sectionStackConstraints)
        sectionStackConstraints = []
        noticeView?.removeFromSuperview()
        noticeView = nil
        floatingHunkHeader.isHidden = true
        updateSideDividerVisibility()
    }

    private func showImagePreview(for file: DiffFile) {
        // Guard: same file already loaded — just update the mode, no re-fetch needed.
        if currentImagePreviewID == file.id, let preview = noticeView as? BinaryImagePreviewView {
            preview.setMode(sideBySide)
            return
        }
        currentImagePreviewID = file.id

        // Tear down any previous state.
        imageFetchTask?.cancel()
        imageFetchTask = nil
        hunkSections.forEach { $0.removeFromSuperview() }
        hunkSections = []
        selectionCoordinator.views = []
        NSLayoutConstraint.deactivate(sectionStackConstraints)
        sectionStackConstraints = []
        noticeView?.removeFromSuperview()
        updateSideDividerVisibility()

        let preview = BinaryImagePreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        outerContent.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: outerContent.leadingAnchor)
                .id("BinaryPreview.leading"),
            preview.trailingAnchor.constraint(equalTo: outerContent.trailingAnchor)
                .id("BinaryPreview.trailing"),
            preview.topAnchor.constraint(equalTo: outerContent.topAnchor)
                .id("BinaryPreview.top"),
            preview.bottomAnchor.constraint(equalTo: outerContent.bottomAnchor)
                .id("BinaryPreview.bottom"),
        ])
        noticeView = preview
        let initialMode = sideBySide
        preview.setLoading(sideBySide: initialMode)

        guard let source else { return }
        imageFetchTask = Task { @MainActor [weak self, weak source] in
            guard let source else { return }
            let (beforeData, afterData) = await source.imagePreviews(for: file)
            guard !Task.isCancelled,
                  let self,
                  let preview = self.noticeView as? BinaryImagePreviewView else { return }
            preview.configure(
                before: beforeData.flatMap { NSImage(data: $0) },
                after:  afterData.flatMap  { NSImage(data: $0) },
                sideBySide: self.sideBySide
            )
        }
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
                             contentMinWidth: CGFloat, gutterWidth: CGFloat) -> HunkSectionView {
        let section: HunkSectionView
        if let existing = hunkSections.first(where: { $0.hunkIndex == index }) {
            section = existing
        } else {
            section = HunkSectionView(hunkIndex: index)
            section.onToggle = { [weak self] in self?.toggleHunk(index) }
        }
        // Mode must precede rows so the right content view(s) exist before we push data in.
        section.configureSideBySide(sideBySide)
        section.gutterWidth = gutterWidth
        section.contentMinWidth = contentMinWidth
        section.headerText = text
        section.rows = rows
        return section
    }

    private func installSections(_ sections: [HunkSectionView]) {
        // Drop sections that are no longer needed.
        let removed = Set(hunkSections).subtracting(sections)
        removed.forEach { $0.removeFromSuperview() }
        hunkSections = sections
        selectionCoordinator.views = sections.flatMap { $0.contentViews }

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

    private static func gutterWidth(for file: DiffFile) -> CGFloat {
        let maxNum = file.hunks.flatMap(\.lines)
            .flatMap { [$0.oldLineNumber, $0.newLineNumber] }
            .compactMap { $0 }
            .max() ?? 1
        let digits = max(1, String(maxNum).count)
        let charWidth = Theme.Font.codeGutter.maximumAdvancement.width
        return ceil(CGFloat(digits) * charWidth) + 10
    }

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

/// Per-hunk section: a header strip plus an inner scroll view that hosts one (unified) or two
/// (side-by-side) `DiffHunkContentView`s. The outer scroll view, sticky header, and collapsing
/// all operate on the section's frame — they don't care what's inside, so they survived the
/// move away from NSTableView.
@objc(HunkSectionView)
private final class HunkSectionView: NSView {
    let hunkIndex: Int
    var contentMinWidth: CGFloat = 0
    var onToggle: (() -> Void)?

    var headerText: String = "" {
        didSet { headerLabel.stringValue = (isCollapsed ? "▸ " : "▾ ") + headerText }
    }
    var isCollapsed: Bool = false {
        didSet {
            headerLabel.stringValue = (isCollapsed ? "▸ " : "▾ ") + headerText
            innerScroll.isHidden = isCollapsed
            updateInnerHeight()
        }
    }

    var rows: [HunkRow] = [] {
        didSet { applyRowsToContent() }
    }

    var gutterWidth: CGFloat = 32 {
        didSet {
            guard abs(gutterWidth - oldValue) > 0.5 else { return }
            applyColumnLayouts()
        }
    }

    let innerScroll: HorizontalScrollView
    private let headerLabel: NSTextField
    private let headerBg: NSView
    private let documentContainer = FlippedView()
    private var documentWidthConstraint: NSLayoutConstraint!
    private var documentHeightConstraint: NSLayoutConstraint!
    private var innerHeightConstraint: NSLayoutConstraint!

    /// Unified-mode content view. Non-nil exactly when `sideBySide == false`.
    private var unifiedView: DiffHunkContentView?
    /// Side-by-side left/right pair. Non-nil exactly when `sideBySide == true`.
    private var leftView: DiffHunkContentView?
    private var rightView: DiffHunkContentView?
    private var splitSeparator: NSView?
    private var leftWidthConstraint: NSLayoutConstraint?
    private var splitFraction: CGFloat = 0.5

    private var sideBySide = false
    /// True when the unified-mode content is wider than the viewport (horizontal scroller shown).
    private var hasHorizontalOverflow = false

    /// Every `DiffHunkContentView` this section currently owns — used by the controller's
    /// selection coordinator to enumerate all selectable views across the diff.
    var contentViews: [DiffHunkContentView] {
        if sideBySide {
            return [leftView, rightView].compactMap { $0 }
        }
        return unifiedView.map { [$0] } ?? []
    }

    private var scrollerAllowance: CGFloat {
        guard hasHorizontalOverflow, innerScroll.scrollerStyle == .legacy else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    private func updateInnerHeight() {
        guard !isCollapsed, !rows.isEmpty else {
            innerHeightConstraint.constant = 0
            documentHeightConstraint.constant = 0
            return
        }
        let h = CGFloat(rows.count) * Theme.Metric.diffLineHeight
        documentHeightConstraint.constant = h
        innerHeightConstraint.constant = h + scrollerAllowance
    }

    init(hunkIndex: Int) {
        self.hunkIndex = hunkIndex

        headerLabel = NSTextField(labelWithString: "")
        headerLabel.font = Theme.Font.codeMeta
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        headerBg = NSView()
        headerBg.wantsLayer = true
        headerBg.translatesAutoresizingMaskIntoConstraints = false

        innerScroll = HorizontalScrollView()
        innerScroll.drawsBackground = false
        innerScroll.hasHorizontalScroller = true
        innerScroll.hasVerticalScroller = false
        innerScroll.autohidesScrollers = true
        innerScroll.borderType = .noBorder
        innerScroll.horizontalScrollElasticity = .none
        innerScroll.verticalScrollElasticity = .none
        innerScroll.automaticallyAdjustsContentInsets = false
        innerScroll.translatesAutoresizingMaskIntoConstraints = false

        documentContainer.translatesAutoresizingMaskIntoConstraints = false
        innerScroll.documentView = documentContainer

        super.init(frame: .zero)

        addSubview(headerBg)
        headerBg.addSubview(headerLabel)
        addSubview(innerScroll)

        innerHeightConstraint = innerScroll.heightAnchor.constraint(equalToConstant: 0)
            .id("HunkSection.innerScroll.height")
        documentWidthConstraint = documentContainer.widthAnchor.constraint(equalToConstant: 100)
            .id("HunkSection.document.width")
        documentHeightConstraint = documentContainer.heightAnchor.constraint(equalToConstant: 0)
            .id("HunkSection.document.height")

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

            documentContainer.topAnchor.constraint(equalTo: innerScroll.contentView.topAnchor)
                .id("HunkSection.document.top"),
            documentContainer.leadingAnchor.constraint(equalTo: innerScroll.contentView.leadingAnchor)
                .id("HunkSection.document.leading"),
            documentWidthConstraint,
            documentHeightConstraint,
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

    // MARK: - Mode

    func configureSideBySide(_ sideBySide: Bool) {
        guard self.sideBySide != sideBySide || (sideBySide ? leftView == nil : unifiedView == nil) else {
            return
        }
        self.sideBySide = sideBySide
        // Tear down whatever is there.
        unifiedView?.removeFromSuperview(); unifiedView = nil
        leftView?.removeFromSuperview(); leftView = nil
        rightView?.removeFromSuperview(); rightView = nil
        splitSeparator?.removeFromSuperview(); splitSeparator = nil
        leftWidthConstraint = nil

        if sideBySide {
            installSideBySideViews()
        } else {
            installUnifiedView()
        }
    }

    private func installUnifiedView() {
        let v = DiffHunkContentView(layout: .unified(gutterWidth: gutterWidth))
        v.hunkIndex = hunkIndex
        v.translatesAutoresizingMaskIntoConstraints = false
        documentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: documentContainer.leadingAnchor)
                .id("HunkSection.unifiedView.leading"),
            v.trailingAnchor.constraint(equalTo: documentContainer.trailingAnchor)
                .id("HunkSection.unifiedView.trailing"),
            v.topAnchor.constraint(equalTo: documentContainer.topAnchor)
                .id("HunkSection.unifiedView.top"),
            v.bottomAnchor.constraint(equalTo: documentContainer.bottomAnchor)
                .id("HunkSection.unifiedView.bottom"),
        ])
        unifiedView = v
        applyRowsToContent()
    }

    private func installSideBySideViews() {
        let left = DiffHunkContentView(layout: .sideBySide(side: .left, gutterWidth: gutterWidth))
        let right = DiffHunkContentView(layout: .sideBySide(side: .right, gutterWidth: gutterWidth))
        let sep = NSView()
        sep.wantsLayer = true
        sep.translatesAutoresizingMaskIntoConstraints = false
        for v: NSView in [left, right] {
            v.translatesAutoresizingMaskIntoConstraints = false
            documentContainer.addSubview(v)
            // Side-by-side clips long lines rather than scrolling horizontally.
            v.wantsLayer = true; v.layer?.masksToBounds = true
        }
        documentContainer.addSubview(sep)

        left.hunkIndex = hunkIndex
        right.hunkIndex = hunkIndex
        leftView = left
        rightView = right
        splitSeparator = sep

        let leftW = left.widthAnchor.constraint(equalTo: documentContainer.widthAnchor,
                                                multiplier: splitFraction)
            .id("HunkSection.left.width")
        leftWidthConstraint = leftW

        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: documentContainer.leadingAnchor)
                .id("HunkSection.left.leading"),
            left.topAnchor.constraint(equalTo: documentContainer.topAnchor)
                .id("HunkSection.left.top"),
            left.bottomAnchor.constraint(equalTo: documentContainer.bottomAnchor)
                .id("HunkSection.left.bottom"),
            leftW,

            sep.leadingAnchor.constraint(equalTo: left.trailingAnchor)
                .id("HunkSection.sep.leading"),
            sep.topAnchor.constraint(equalTo: documentContainer.topAnchor)
                .id("HunkSection.sep.top"),
            sep.bottomAnchor.constraint(equalTo: documentContainer.bottomAnchor)
                .id("HunkSection.sep.bottom"),
            sep.widthAnchor.constraint(equalToConstant: 1)
                .id("HunkSection.sep.width"),

            right.leadingAnchor.constraint(equalTo: sep.trailingAnchor)
                .id("HunkSection.right.leading"),
            right.trailingAnchor.constraint(equalTo: documentContainer.trailingAnchor)
                .id("HunkSection.right.trailing"),
            right.topAnchor.constraint(equalTo: documentContainer.topAnchor)
                .id("HunkSection.right.top"),
            right.bottomAnchor.constraint(equalTo: documentContainer.bottomAnchor)
                .id("HunkSection.right.bottom"),
        ])

        sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        applyRowsToContent()
    }

    private func applyColumnLayouts() {
        unifiedView?.columnLayout = .unified(gutterWidth: gutterWidth)
        leftView?.columnLayout = .sideBySide(side: .left, gutterWidth: gutterWidth)
        rightView?.columnLayout = .sideBySide(side: .right, gutterWidth: gutterWidth)
    }

    // MARK: - Rows

    private func applyRowsToContent() {
        if let v = unifiedView {
            v.rows = rows.map { row -> DiffContentRow in
                switch row {
                case .line(let l):
                    return DiffContentRow(line: l, oldNumber: l.oldLineNumber, newNumber: l.newLineNumber)
                case .pair:
                    // Defensive: a pair row in unified mode shouldn't happen, but treat as blank.
                    return .blank
                }
            }
        }
        if let lv = leftView, let rv = rightView {
            lv.rows = rows.map { row in
                switch row {
                case .pair(let left, _):
                    return DiffContentRow(line: left, oldNumber: left?.oldLineNumber, newNumber: nil)
                case .line(let l):
                    return DiffContentRow(line: l, oldNumber: l.oldLineNumber, newNumber: nil)
                }
            }
            rv.rows = rows.map { row in
                switch row {
                case .pair(_, let right):
                    return DiffContentRow(line: right, oldNumber: nil, newNumber: right?.newLineNumber)
                case .line(let l):
                    return DiffContentRow(line: l, oldNumber: nil, newNumber: l.newLineNumber)
                }
            }
        }
        updateInnerHeight()
    }

    // MARK: - Width

    func updateContentColumnWidth(available: CGFloat) {
        // Unified: documentContainer = max(natural intrinsic width, viewport).
        // Side-by-side: documentContainer = viewport exactly; left/right share it via split fraction.
        if sideBySide {
            documentWidthConstraint.constant = max(available, 100)
            if hasHorizontalOverflow { hasHorizontalOverflow = false; updateInnerHeight() }
        } else {
            let intrinsic = unifiedView?.intrinsicContentSize.width ?? 0
            let naturalWidth = max(intrinsic, contentMinWidth)
            let target = max(naturalWidth, available, 100)
            documentWidthConstraint.constant = target
            let overflow = target > available + 0.5
            if overflow != hasHorizontalOverflow {
                hasHorizontalOverflow = overflow
                updateInnerHeight()
            }
        }
    }

    /// Re-balance the side-by-side halves when the user drags the centre divider.
    /// The multiplier of an NSLayoutConstraint is immutable, so we recreate it.
    func applySplitFraction(_ fraction: CGFloat) {
        splitFraction = fraction
        guard let left = leftView, let oldConstraint = leftWidthConstraint else { return }
        oldConstraint.isActive = false
        let new = left.widthAnchor.constraint(equalTo: documentContainer.widthAnchor,
                                              multiplier: fraction)
            .id("HunkSection.left.width")
        new.isActive = true
        leftWidthConstraint = new
    }
}


// MARK: - Responder-chain copy (multi-hunk selections)

extension DiffViewController {
    /// First-responder `copy:` fallback when the focused content view's own copy is bypassed
    /// (e.g. the menu item is invoked while focus is on the controller's view). Coordinator
    /// concatenates whatever the selected hunks contribute.
    @objc func copy(_ sender: Any?) {
        guard let text = selectionCoordinator.combinedSelectedText(), !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return selectionCoordinator.combinedSelectedText()?.isEmpty == false
        }
        return true
    }
}

// MARK: - Flipped document view

/// NSScrollView places non-flipped document views at the bottom of the visible area when
/// the content is shorter than the viewport. Flipping the document view pins it to the top.
@objc(DiffFlippedView)
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Sticky hunk header overlay

/// Floats at the top of the diff scroll view, showing the header of the hunk whose
/// own header has scrolled out of view. Unlike the inline hunk header (which sits over the
/// pane's own background), this overlay sits *on top of scrolling diff text* — so it needs an
/// opaque material backing, otherwise the lines beneath bleed through and it looks broken.
@objc(DiffFloatingHunkHeaderView)
private final class FloatingHunkHeaderView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let tint = NSView()
    private let hairline = NSView()

    var onToggle: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .headerView
        blendingMode = .withinWindow
        state = .active

        let click = NSClickGestureRecognizer(target: self, action: #selector(headerTapped))
        addGestureRecognizer(click)

        // The same subtle hunk tint the inline headers carry, layered over the opaque material.
        tint.wantsLayer = true
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)

        hairline.wantsLayer = true
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        label.font = Theme.Font.codeMeta
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor),

            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String) { label.stringValue = text }

    @objc private func headerTapped() { onToggle?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func layout() {
        super.layout()
        tint.layer?.backgroundColor = Theme.Color.hunkBackground.cgColor
        hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

// MARK: - Horizontal-only scroll view

/// A scroll view that only handles horizontal scroll events, passing vertical ones up the
/// responder chain to the outer scroll view. Without this, each inner hunk scroll view
/// rubber-bands vertically on a trackpad, stealing events and making the outer scroll jerky.
@objc(DiffHorizontalScrollView)
private final class HorizontalScrollView: NSScrollView {
    // Locked at .began so momentum events stay on the same axis.
    private var handlingHorizontally = false

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began {
            handlingHorizontally = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
        } else if event.phase.isEmpty && event.momentumPhase.isEmpty {
            // Non-trackpad scroll wheel: decide per-event.
            handlingHorizontally = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        if handlingHorizontally {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

}

// MARK: - Side-by-side draggable divider

/// A thin, full-height handle the user drags to rebalance the two halves of the side-by-side
/// view. Reports its centre x (in the diff container's coordinates) while dragging.
@objc(DiffSideBySideDividerView)
private final class SideBySideDividerView: NSView {
    static let width: CGFloat = 11

    var onDragToX: ((CGFloat) -> Void)?

    private let line = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.centerXAnchor.constraint(equalTo: centerXAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    // Drag anywhere on the handle; report the location in the superview's (container's) space.
    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDragToX?(superview.convert(event.locationInWindow, from: nil).x)
    }
    // Swallow mouseDown so the drag begins cleanly.
    override func mouseDown(with event: NSEvent) {}
}

// MARK: - File header

@objc(DiffHeaderView)
private final class DiffHeaderView: NSView {
    private let icon = NSImageView()
    private let areaBadgeStack = NSStackView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let statLabel = NSTextField(labelWithString: "")
    private let signalStack = NSStackView()
    private let showButton = NSButton(title: "Show anyway", target: nil, action: nil)
    private let focusButton = NSButton(title: "Focus", target: nil, action: nil)
    private let contextButton = NSButton(title: "", target: nil, action: nil)
    private let modeButton = NSButton(title: "", target: nil, action: nil)
    private let divider = NSBox()

    var onExpandNoise: (() -> Void)?
    var onToggleFocus: (() -> Void)?
    var onToggleContext: (() -> Void)?
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

        contextButton.bezelStyle = .accessoryBarAction
        contextButton.controlSize = .small
        contextButton.setButtonType(.pushOnPushOff)
        contextButton.image = NSImage(systemSymbolName: "arrow.up.and.down.text.horizontal",
                                      accessibilityDescription: "Show whole file")
        contextButton.imagePosition = .imageOnly
        contextButton.target = self; contextButton.action = #selector(contextTapped)
        contextButton.toolTip = "Show the whole file around the changes"
        contextButton.translatesAutoresizingMaskIntoConstraints = false

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

        // Left group: info elements that can shrink when space is tight.
        let leftRow = NSStackView(views: [icon, areaBadgeStack, pathLabel, signalStack,
                                          showButton, focusButton])
        leftRow.orientation = .horizontal; leftRow.spacing = 8; leftRow.alignment = .centerY
        leftRow.translatesAutoresizingMaskIntoConstraints = false
        leftRow.setCustomSpacing(10, after: pathLabel)

        // Right group: stat + context/mode toggles — always pinned to the trailing edge.
        let rightRow = NSStackView(views: [statLabel, contextButton, modeButton])
        rightRow.orientation = .horizontal; rightRow.spacing = 8; rightRow.alignment = .centerY
        rightRow.translatesAutoresizingMaskIntoConstraints = false
        rightRow.setHuggingPriority(.required, for: .horizontal)

        addSubview(leftRow); addSubview(rightRow); addSubview(divider)

        clipsToBounds = true
        NSLayoutConstraint.activate([
            leftRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metric.pad)
                .id("DiffHeader.leftRow.leading"),
            leftRow.topAnchor.constraint(equalTo: topAnchor, constant: 8)
                .id("DiffHeader.leftRow.top"),
            leftRow.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -8)
                .id("DiffHeader.leftRow.bottom"),
                {
                let c = leftRow.trailingAnchor.constraint(lessThanOrEqualTo: rightRow.leadingAnchor,
                                                          constant: -8)
                    .id("DiffHeader.leftRow.trailing")
                c.priority = .defaultHigh
                return c
            }(),

            rightRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Metric.pad)
                .id("DiffHeader.rightRow.trailing"),
            rightRow.centerYAnchor.constraint(equalTo: leftRow.centerYAnchor)
                .id("DiffHeader.rightRow.centerY"),

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
    @objc private func contextTapped() { onToggleContext?() }
    @objc private func modeTapped() { onToggleMode?() }

    func setWholeFile(_ on: Bool) {
        contextButton.state = on ? .on : .off
        contextButton.toolTip = on ? "Show only changed lines (±3 context)"
                                   : "Show the whole file around the changes"
    }

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

// MARK: - Binary image before/after preview

/// Shows a binary image diff. In unified mode: the current version fills the full width.
/// In side-by-side mode: before (left) and after (right) are shown together for comparison.
/// Images are decoded by macOS ImageIO via NSImage(data:) — no custom parsing, no script execution.
@objc(BinaryImagePreviewView)
private final class BinaryImagePreviewView: NSView {
    // Before column — shown only in side-by-side mode.
    private let beforeLabel = NSTextField(labelWithString: "Before")
    private let beforeImage = NSImageView()
    private let beforeNote  = NSTextField(labelWithString: "")
    private let divider     = NSView()

    // After column — present in both modes; layout changes with mode.
    private let afterLabel  = NSTextField(labelWithString: "After")
    private let afterImage  = NSImageView()
    private let afterNote   = NSTextField(labelWithString: "")

    private let spinner = NSProgressIndicator()

    private var cachedBefore: NSImage?
    private var cachedAfter:  NSImage?

    // Constraints swapped between modes.
    private var unifiedConstraints: [NSLayoutConstraint] = []
    private var splitConstraints:   [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)

        beforeLabel.font = Theme.Font.secondary
        beforeLabel.textColor = .secondaryLabelColor
        beforeLabel.translatesAutoresizingMaskIntoConstraints = false

        afterLabel.font = Theme.Font.secondary
        afterLabel.textColor = .secondaryLabelColor
        afterLabel.translatesAutoresizingMaskIntoConstraints = false

        for note in [beforeNote, afterNote] {
            note.font = Theme.Font.secondary
            note.textColor = .tertiaryLabelColor
            note.alignment = .center
            note.translatesAutoresizingMaskIntoConstraints = false
        }

        for iv in [beforeImage, afterImage] {
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.imageAlignment = .alignCenter
            iv.translatesAutoresizingMaskIntoConstraints = false
        }

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true

        [beforeLabel, beforeImage, beforeNote, divider,
         afterLabel, afterImage, afterNote, spinner].forEach(addSubview)

        // Constraints always active regardless of mode.
        NSLayoutConstraint.activate([
            // afterImage: trailing and height never change.
            afterImage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
                .id("BinaryPreview.afterImage.trailing"),
            afterImage.heightAnchor.constraint(equalToConstant: 320)
                .id("BinaryPreview.afterImage.height"),
            // Drives the view's overall height in the scroll view.
            afterImage.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
                .id("BinaryPreview.afterImage.bottom"),

            // Before column: fixed position (hidden in unified mode).
            beforeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
                .id("BinaryPreview.beforeLabel.leading"),
            beforeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12)
                .id("BinaryPreview.beforeLabel.top"),
            beforeImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
                .id("BinaryPreview.beforeImage.leading"),
            beforeImage.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -12)
                .id("BinaryPreview.beforeImage.trailing"),
            beforeImage.topAnchor.constraint(equalTo: beforeLabel.bottomAnchor, constant: 8)
                .id("BinaryPreview.beforeImage.top"),
            beforeImage.heightAnchor.constraint(equalToConstant: 320)
                .id("BinaryPreview.beforeImage.height"),

            // Divider: fixed position (hidden in unified mode).
            divider.centerXAnchor.constraint(equalTo: centerXAnchor)
                .id("BinaryPreview.divider.centerX"),
            divider.topAnchor.constraint(equalTo: topAnchor)
                .id("BinaryPreview.divider.top"),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor)
                .id("BinaryPreview.divider.bottom"),
            divider.widthAnchor.constraint(equalToConstant: 1)
                .id("BinaryPreview.divider.width"),

            beforeNote.centerXAnchor.constraint(equalTo: beforeImage.centerXAnchor)
                .id("BinaryPreview.beforeNote.centerX"),
            beforeNote.centerYAnchor.constraint(equalTo: beforeImage.centerYAnchor)
                .id("BinaryPreview.beforeNote.centerY"),
            afterNote.centerXAnchor.constraint(equalTo: afterImage.centerXAnchor)
                .id("BinaryPreview.afterNote.centerX"),
            afterNote.centerYAnchor.constraint(equalTo: afterImage.centerYAnchor)
                .id("BinaryPreview.afterNote.centerY"),

            spinner.centerXAnchor.constraint(equalTo: centerXAnchor)
                .id("BinaryPreview.spinner.centerX"),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor)
                .id("BinaryPreview.spinner.centerY"),
        ])

        // Unified: afterImage fills full width with top padding, no label above it.
        unifiedConstraints = [
            afterImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
                .id("BinaryPreview.unified.afterImage.leading"),
            afterImage.topAnchor.constraint(equalTo: topAnchor, constant: 12)
                .id("BinaryPreview.unified.afterImage.top"),
        ]

        // Split: afterImage occupies the right half, label above it.
        splitConstraints = [
            afterLabel.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 12)
                .id("BinaryPreview.split.afterLabel.leading"),
            afterLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12)
                .id("BinaryPreview.split.afterLabel.top"),
            afterImage.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 12)
                .id("BinaryPreview.split.afterImage.leading"),
            afterImage.topAnchor.constraint(equalTo: afterLabel.bottomAnchor, constant: 8)
                .id("BinaryPreview.split.afterImage.top"),
        ]
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    func setLoading(sideBySide: Bool) {
        cachedBefore = nil; cachedAfter = nil
        beforeImage.image = nil; afterImage.image = nil
        beforeNote.stringValue = ""; afterNote.stringValue = ""
        spinner.isHidden = false; spinner.startAnimation(nil)
        applyLayout(sideBySide: sideBySide)
    }

    func configure(before: NSImage?, after: NSImage?, sideBySide: Bool) {
        cachedBefore = before; cachedAfter = after
        spinner.stopAnimation(nil); spinner.isHidden = true
        applyImages(sideBySide: sideBySide)
        applyLayout(sideBySide: sideBySide)
    }

    /// Called when the mode toggles without a new file being loaded.
    func setMode(_ sideBySide: Bool) {
        applyImages(sideBySide: sideBySide)
        applyLayout(sideBySide: sideBySide)
    }

    private func applyImages(sideBySide: Bool) {
        if sideBySide {
            beforeImage.image = cachedBefore
            beforeNote.stringValue = cachedBefore == nil ? "No previous version" : ""
            afterImage.image = cachedAfter
            afterNote.stringValue = cachedAfter == nil ? "File deleted" : ""
        } else {
            // Unified: show "after"; fall back to "before" for deleted files.
            afterImage.image = cachedAfter ?? cachedBefore
            afterNote.stringValue = (cachedAfter == nil && cachedBefore == nil) ? "No image data" : ""
        }
    }

    private func applyLayout(sideBySide: Bool) {
        let entering  = sideBySide ? splitConstraints   : unifiedConstraints
        let leaving   = sideBySide ? unifiedConstraints : splitConstraints
        NSLayoutConstraint.deactivate(leaving)
        NSLayoutConstraint.activate(entering)

        let showBefore = sideBySide
        beforeLabel.isHidden = !showBefore
        beforeImage.isHidden = !showBefore
        beforeNote.isHidden  = !showBefore
        divider.isHidden     = !showBefore
        afterLabel.isHidden  = !showBefore
    }
}
