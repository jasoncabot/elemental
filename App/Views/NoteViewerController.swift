import AppKit
import Presenters

/// Shows one git note in full, inside a popover anchored to the note's pill in the commit header.
/// Dragging the popover away tears it off into a floating window that stays open beside the diff.
///
/// Human-written notes read as prose. git-ai authorship logs are written for machines — session
/// and trace hashes keyed to line ranges — so they open on a Summary that resolves every hash to
/// the agent or person it names (who wrote how much, in which files and lines), with the untouched
/// Raw text one click away for anyone who needs the identifiers.
///
/// Every string and colour role comes from `NotePresentation`, which golden tests pin; this class
/// only lays it out.
final class NoteViewerController: NSViewController {
    private let presentation: NotePresentation

    private let modeControl = NSSegmentedControl()
    private var summaryScroll: NSScrollView?
    private var rawScroll: NSScrollView!
    private var summaryHeight: CGFloat = 0
    private var rawHeight: CGFloat = 0
    private var headerHeight: CGFloat = 0

    private static let width: CGFloat = 460
    private static let maxBodyHeight: CGFloat = 460
    private static let inset: CGFloat = 16

    init(presentation: NotePresentation) {
        self.presentation = presentation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()

        // Header: title + "refs/notes/ai · 1a2b3c4", then Summary/Raw (git-ai only) and Copy.
        let title = NSTextField(labelWithString: presentation.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let caption = NSTextField(labelWithString: presentation.caption)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingMiddle
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titles = NSStackView(views: [title, caption])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let copyButton = NSButton(
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy note") ?? NSImage(),
            target: self, action: #selector(copyNote))
        copyButton.isBordered = false
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.toolTip = "Copy note text"

        var headerViews: [NSView] = [titles, spacer]
        if presentation.summary != nil {
            modeControl.segmentCount = 2
            modeControl.setLabel("Summary", forSegment: 0)
            modeControl.setLabel("Raw", forSegment: 1)
            modeControl.trackingMode = .selectOne
            modeControl.selectedSegment = 0
            modeControl.controlSize = .small
            modeControl.target = self
            modeControl.action = #selector(modeChanged)
            headerViews.append(modeControl)
        }
        headerViews.append(copyButton)

        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 12, left: Self.inset, bottom: 10, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(header)
        container.addSubview(divider)

        let raw = makeTextScroll()
        rawScroll = raw.scroll
        rawHeight = raw.height
        var bodies: [(view: NSScrollView, name: String)] = [(raw.scroll, "raw")]
        if let summary = presentation.summary {
            let built = makeSummaryScroll(summary)
            summaryScroll = built.scroll
            summaryHeight = built.height
            bodies.append((built.scroll, "summary"))
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor).id("NoteViewer.header.top"),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor).id("NoteViewer.header.leading"),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor).id("NoteViewer.header.trailing"),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor).id("NoteViewer.divider.top"),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor).id("NoteViewer.divider.leading"),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor).id("NoteViewer.divider.trailing"),
        ])
        for body in bodies {
            body.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(body.view)
            NSLayoutConstraint.activate([
                body.view.topAnchor.constraint(equalTo: divider.bottomAnchor)
                    .id("NoteViewer.\(body.name).top"),
                body.view.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                    .id("NoteViewer.\(body.name).leading"),
                body.view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
                    .id("NoteViewer.\(body.name).trailing"),
                body.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
                    .id("NoteViewer.\(body.name).bottom"),
            ])
        }

        headerHeight = header.fittingSize.height + 1
        view = container
        applyMode()
    }

    private var showsRaw: Bool { summaryScroll == nil || modeControl.selectedSegment == 1 }

    @objc private func modeChanged() { applyMode() }

    /// Swaps the visible body and resizes to fit it; a popover animates the size change natively.
    private func applyMode() {
        summaryScroll?.isHidden = showsRaw
        rawScroll.isHidden = !showsRaw
        let body = min(showsRaw ? rawHeight : summaryHeight, Self.maxBodyHeight)
        preferredContentSize = NSSize(width: Self.width, height: headerHeight + body)
    }

    @objc private func copyNote() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(presentation.rawText, forType: .string)
    }

    // MARK: - Raw / prose text

    private func makeTextScroll() -> (scroll: NSScrollView, height: CGFloat) {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        // git-ai logs keep their column structure in a monospaced face; prose gets reading leading.
        let isMonospaced = presentation.rawStyle == .monospaced
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = isMonospaced ? 1.1 : 1.3
        let text = NSAttributedString(string: presentation.rawText, attributes: [
            .font: isMonospaced ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                                : NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])

        let hPad: CGFloat = Self.inset - 5
        let vPad: CGFloat = 12
        var padding: CGFloat = 5
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: hPad, height: vPad)
            textView.textStorage?.setAttributedString(text)
            padding = textView.textContainer?.lineFragmentPadding ?? padding
        }

        let wrapWidth = Self.width - 2 * hPad - 2 * padding
        let rect = text.boundingRect(with: NSSize(width: wrapWidth, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        return (scroll, ceil(rect.height) + 2 * vPad)
    }

    // MARK: - git-ai summary

    private func makeSummaryScroll(_ summary: AuthorshipSummary) -> (scroll: NSScrollView, height: CGFloat) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        var rowIndex = 0
        func add(_ view: NSView, spacingAfter: CGFloat? = nil) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor)
                .id("NoteViewer.summaryRow\(rowIndex).width").isActive = true
            rowIndex += 1
            if let spacingAfter { stack.setCustomSpacing(spacingAfter, after: view) }
        }

        // Overview: one sentence and a share bar, so the headline answer needs no reading.
        let overview = NSTextField(wrappingLabelWithString: summary.overview)
        overview.font = .systemFont(ofSize: 13)
        overview.textColor = .labelColor
        overview.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
        add(overview, spacingAfter: 8)

        if !summary.shares.isEmpty {
            add(ShareBar(segments: summary.shares.map { (CGFloat($0.fraction), $0.swatch.color) }),
                spacingAfter: 16)
        }

        // Contributors: who they are in human terms. Hashes live only in the tooltip.
        add(Self.sectionCaption("Contributors"), spacingAfter: 6)
        for c in summary.contributors {
            add(Self.contributorBlock(c), spacingAfter: 10)
        }

        // Files: per file, which contributor wrote which lines.
        if !summary.files.isEmpty {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(16, after: last) }
            add(Self.sectionCaption("Files"), spacingAfter: 6)
            for file in summary.files {
                add(Self.countRow(dot: nil, title: file.path, titleFont: .systemFont(ofSize: 12, weight: .medium),
                                  detail: nil, count: file.countText, truncation: .byTruncatingMiddle),
                    spacingAfter: 3)
                for (i, a) in file.attributions.enumerated() {
                    let row = Self.countRow(dot: a.swatch.color, title: a.name, titleFont: .systemFont(ofSize: 12),
                                            detail: a.rangesText, count: a.countText,
                                            truncation: .byTruncatingTail)
                    add(Self.indented(row, by: 12),
                        spacingAfter: i == file.attributions.count - 1 ? 10 : 3)
                }
            }
        }

        let footer = Self.label(summary.footer, font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
        footer.toolTip = summary.footerTooltip
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }
        add(footer)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let vPad: CGFloat = 14
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: vPad).id("NoteViewer.summary.top"),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: Self.inset)
                .id("NoteViewer.summary.leading"),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -Self.inset)
                .id("NoteViewer.summary.trailing"),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -vPad)
                .id("NoteViewer.summary.bottom"),
        ])

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).id("NoteViewer.doc.top"),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).id("NoteViewer.doc.leading"),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).id("NoteViewer.doc.width"),
        ])

        // Every row is single-line (or wraps at a fixed width), so the fitting height is exact.
        return (scroll, ceil(stack.fittingSize.height) + 2 * vPad)
    }

    private static func contributorBlock(_ c: AuthorshipSummary.Contributor) -> NSView {
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 2
        let head = countRow(dot: c.swatch.color, title: c.name, titleFont: .systemFont(ofSize: 13, weight: .semibold),
                            detail: nil, count: c.countText, truncation: .byTruncatingTail)
        block.addArrangedSubview(head)
        head.widthAnchor.constraint(equalTo: block.widthAnchor).id("NoteViewer.contributor.head.width").isActive = true
        for (i, d) in c.details.enumerated() {
            let l = label(d, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            l.toolTip = d
            let row = indented(l, by: 16)
            block.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: block.widthAnchor)
                .id("NoteViewer.contributor.detail\(i).width").isActive = true
        }
        block.toolTip = c.tooltip
        return block
    }

    /// `●  Title   detail ………………   42 lines` — a single line whose count stays right-aligned.
    private static func countRow(dot: NSColor?, title: String, titleFont: NSFont, detail: String?,
                                 count: String, truncation: NSLineBreakMode) -> NSView {
        var views: [NSView] = []
        if let dot { views.append(DotView(color: dot)) }
        let titleLabel = label(title, font: titleFont, color: .labelColor)
        titleLabel.lineBreakMode = truncation
        titleLabel.toolTip = title
        views.append(titleLabel)
        if let detail {
            let d = label(detail, font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                          color: .secondaryLabelColor)
            d.toolTip = detail
            d.setContentCompressionResistancePriority(.init(rawValue: 249), for: .horizontal)
            views.append(d)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        views.append(spacer)
        let countLabel = label(count, font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                               color: .secondaryLabelColor)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        views.append(countLabel)

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = dot != nil ? .centerY : .firstBaseline
        row.spacing = 8
        return row
    }

    private static func indented(_ view: NSView, by amount: CGFloat) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: wrapper.topAnchor).id("NoteViewer.indented.top"),
            view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor).id("NoteViewer.indented.bottom"),
            view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: amount)
                .id("NoteViewer.indented.leading"),
            view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor).id("NoteViewer.indented.trailing"),
        ])
        return wrapper
    }

    private static func sectionCaption(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 1.2,
        ])
        return l
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }
}

// MARK: - Small drawing views

@objc(NoteViewerFlippedView)
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A filled circle in a dynamic system color (drawn, so it follows light/dark changes).
@objc(NoteViewerDotView)
private final class DotView: NSView {
    private let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 8).id("DotView.width"),
            heightAnchor.constraint(equalToConstant: 8).id("DotView.height"),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// A thin rounded bar split into proportional colored segments — the share of attributed lines.
@objc(NoteViewerShareBar)
private final class ShareBar: NSView {
    private let segments: [(fraction: CGFloat, color: NSColor)]
    init(segments: [(CGFloat, NSColor)]) {
        self.segments = segments.map { (fraction: $0.0, color: $0.1) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 6).id("ShareBar.height").isActive = true
        setAccessibilityElement(false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).addClip()
        NSColor.quaternaryLabelColor.setFill()
        bounds.fill()
        var x = bounds.minX
        for s in segments {
            let w = bounds.width * s.fraction
            s.color.setFill()
            NSRect(x: x, y: bounds.minY, width: w, height: bounds.height).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
