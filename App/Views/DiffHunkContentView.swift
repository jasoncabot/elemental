import AppKit
import GitData

/// A single visual row inside a diff hunk content view.
///
/// `line` is `nil` for blank placeholder rows used in side-by-side mode to keep paired rows
/// vertically aligned when one side has no counterpart. Blank rows are not selectable and copy
/// as an empty line.
struct DiffContentRow {
    let line: DiffLine?
    /// The number to show in this column's gutter. In unified mode the view shows two gutters
    /// (old + new); in side-by-side each view shows one. `nil` = blank cell.
    let oldNumber: Int?
    let newNumber: Int?

    static let blank = DiffContentRow(line: nil, oldNumber: nil, newNumber: nil)
}

/// What the content view renders to the left of the text — fixed across all its rows.
enum DiffContentLayout {
    /// Two gutters (old, new) and a marker column (+/−/space).
    case unified(gutterWidth: CGFloat)
    /// One gutter; no marker column. Background colour alone denotes added/removed.
    case sideBySide(side: SideBySideSide, gutterWidth: CGFloat)

    enum SideBySideSide { case left, right }
}

/// Selection inside a single content view. Two mutually-exclusive modes mirror the user's
/// gesture — clicking inside the text region selects characters; clicking the gutter selects
/// whole lines. A single drag can extend within one mode but never switches modes mid-drag.
enum DiffContentSelection: Equatable {
    case none
    /// `(startRow, startChar) ... (endRow, endChar)` — start always ≤ end. `endChar` is the
    /// *exclusive* character index in the end row's text. For a single-row selection,
    /// `startRow == endRow`.
    case text(startRow: Int, startChar: Int, endRow: Int, endChar: Int)
    case lines(IndexSet)

    var isEmpty: Bool {
        switch self {
        case .none: return true
        case .text(let sR, let sC, let eR, let eC): return sR == eR && sC == eC
        case .lines(let s): return s.isEmpty
        }
    }
}

protocol DiffHunkContentViewDelegate: AnyObject {
    /// The view is about to start a new selection (mouseDown without shift). Coordinator should
    /// clear selection in every other view so only one hunk shows a selection at a time.
    func contentViewWillBeginSelection(_ view: DiffHunkContentView)
    /// The view's selection changed (drag, click, clear). Coordinator can update menu state.
    func contentViewDidChangeSelection(_ view: DiffHunkContentView)
    /// Cross-hunk drag: the user is dragging past the view's bounds. `pointInWindow` is the
    /// current mouse location. Coordinator should find the adjacent hunk under that point and
    /// extend the selection into it. Return `true` if the coordinator handled it so the view
    /// can skip its own out-of-bounds extension logic.
    @discardableResult
    func contentView(_ view: DiffHunkContentView, didDragOutsideTo pointInWindow: NSPoint) -> Bool
    /// When the user presses Cmd-C on this view, the delegate gets first chance to provide
    /// the pasteboard string — used by the coordinator to return text spanning multiple hunks.
    /// Return `nil` to fall back to this view's own slice.
    func combinedCopyText(forActive view: DiffHunkContentView) -> String?
}

extension DiffHunkContentViewDelegate {
    func contentViewWillBeginSelection(_ view: DiffHunkContentView) {}
    func contentViewDidChangeSelection(_ view: DiffHunkContentView) {}
    func contentView(_ view: DiffHunkContentView, didDragOutsideTo pointInWindow: NSPoint) -> Bool {
        false
    }
    func combinedCopyText(forActive view: DiffHunkContentView) -> String? { nil }
}

/// A custom flipped NSView that renders one diff hunk's lines via Core Text and owns its own
/// selection state. Markers (`+`/`−`) and gutter numbers are drawn separately from the content
/// CTLines, so they can never end up on the pasteboard.
///
/// One row = one `CTLine`. We deliberately avoid `CTFramesetter`/`CTFrame` because each row is
/// a single unwrapped line of monospace code — framing adds no value and would impose a width
/// constraint that conflicts with horizontal scrolling for long lines.
@objc(DiffHunkContentView)
final class DiffHunkContentView: NSView {

    // MARK: - Layout constants

    /// Pixels of right-side padding inside each gutter column.
    private static let gutterInsetRight: CGFloat = 6
    /// Pixels between the marker column and the text.
    private static let markerToTextGap: CGFloat = 4
    /// Pixels of left padding before the text in side-by-side mode (no marker column).
    private static let textInsetLeftSideBySide: CGFloat = 6
    /// Padding to leave at the right edge so the last character isn't flush against the scroll bar.
    private static let textInsetRight: CGFloat = 8

    // MARK: - Public configuration

    weak var delegate: DiffHunkContentViewDelegate?

    /// All rows in this hunk. Setting this invalidates everything and re-renders.
    var rows: [DiffContentRow] = [] {
        didSet { rebuildLines() }
    }

    var columnLayout: DiffContentLayout {
        didSet { invalidateMarkers(); invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    /// Current selection. Setting from outside (e.g. coordinator) updates the overlay layer
    /// without notifying the delegate.
    var selection: DiffContentSelection = .none {
        didSet {
            guard selection != oldValue else { return }
            updateSelectionOverlay()
        }
    }

    /// Identifies which logical hunk this view belongs to — used by the coordinator to scope
    /// cross-hunk selection.
    var hunkIndex: Int = 0

    // MARK: - Cached typography & per-row data

    private var font: NSFont = Theme.Font.code()
    private var gutterFont: NSFont = Theme.Font.codeGutter
    private var ascent: CGFloat = 0
    private var descent: CGFloat = 0
    private var lineHeight: CGFloat = Theme.Metric.diffLineHeight

    /// Per-row prepared content line. Index aligns with `rows`. `nil` for blank placeholder rows.
    private var contentLines: [CTLine?] = []
    /// The widest content line (used for intrinsic width / horizontal scrolling).
    private var maxContentLineWidth: CGFloat = 0

    /// Prebuilt marker glyph runs reused across all rows. Recreated when font size changes.
    private var addedMarkerLine: CTLine?
    private var removedMarkerLine: CTLine?
    private var contextMarkerLine: CTLine?
    /// Width of any marker glyph (monospace, so all three are identical).
    private var markerGlyphWidth: CGFloat = 0

    // MARK: - Selection drawing

    /// Cached rects of the current selection in view coordinates. Recomputed when `selection`
    /// changes; consumed by `draw(_:)` so glyphs render on top of the fill (otherwise the
    /// highlight would mask the text).
    private var selectionRects: [NSRect] = []

    /// Drag state — set on `mouseDown`, consumed by `mouseDragged`/`mouseUp`.
    private enum DragMode {
        case none
        case text(anchorRow: Int, anchorChar: Int, granularity: Granularity)
        case lines(anchorRow: Int, baseline: IndexSet, op: LineOp)
        enum Granularity { case character, word, line }
        enum LineOp { case replace, extend, toggle }
    }
    private var dragMode: DragMode = .none

    // MARK: - Init

    init(layout: DiffContentLayout) {
        self.columnLayout = layout
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeDidChange),
                                               name: .diffFontSizeDidChange, object: nil)
        rebuildTypography()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        windowKeyDidChange()
        return true
    }
    override func resignFirstResponder() -> Bool {
        windowKeyDidChange()
        return true
    }

    // MARK: - Layout metrics

    private var oldGutterWidth: CGFloat {
        switch columnLayout {
        case .unified(let w): return w
        case .sideBySide: return 0
        }
    }
    private var newGutterWidth: CGFloat {
        switch columnLayout {
        case .unified(let w): return w
        case .sideBySide(_, let w): return w
        }
    }
    private var hasMarkerColumn: Bool {
        if case .unified = columnLayout { return true }; return false
    }
    private var markerColumnWidth: CGFloat {
        hasMarkerColumn ? markerGlyphWidth + Self.markerToTextGap : 0
    }
    private var textStartX: CGFloat {
        oldGutterWidth + newGutterWidth + markerColumnWidth
            + (hasMarkerColumn ? 0 : Self.textInsetLeftSideBySide)
    }

    // MARK: - Typography

    @objc private func fontSizeDidChange() {
        rebuildTypography()
        rebuildLines()
    }

    private func rebuildTypography() {
        font = Theme.Font.code()
        gutterFont = Theme.Font.codeGutter
        lineHeight = Theme.Metric.diffLineHeight

        // Ascent/descent for vertical centring of the baseline within the row.
        let measure = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, "M" as CFString,
                                     [kCTFontAttributeName: font] as CFDictionary))
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        _ = CTLineGetTypographicBounds(measure, &a, &d, &l)
        ascent = a
        descent = d
        invalidateMarkers()
    }

    private func invalidateMarkers() {
        addedMarkerLine = nil; removedMarkerLine = nil; contextMarkerLine = nil
        markerGlyphWidth = 0
        if hasMarkerColumn {
            addedMarkerLine = makeMarkerLine("+", color: Theme.Color.addedText)
            removedMarkerLine = makeMarkerLine("−", color: Theme.Color.removedText)
            contextMarkerLine = makeMarkerLine(" ", color: .secondaryLabelColor)
            if let added = addedMarkerLine {
                var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
                let w = CGFloat(CTLineGetTypographicBounds(added, &a, &d, &l))
                markerGlyphWidth = ceil(w)
            }
        }
    }

    private func makeMarkerLine(_ glyph: String, color: NSColor) -> CTLine {
        // Foreground-from-context lets us re-fill per draw so dynamic colours track appearance.
        let attrs: CFDictionary = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: kCFBooleanTrue!,
        ] as CFDictionary
        let s = CFAttributedStringCreate(nil, glyph as CFString, attrs)!
        return CTLineCreateWithAttributedString(s)
    }

    private func rebuildLines() {
        contentLines = rows.map { row -> CTLine? in
            guard let line = row.line else { return nil }
            // Replace tabs with spaces visually (4 spaces). Keeps width predictable for
            // monospace alignment and click-to-character math; the copied text preserves tabs
            // because we copy from `DiffLine.text`, not the rendered string.
            let visible = line.text.replacingOccurrences(of: "\t", with: "    ")
            let attrs: CFDictionary = [
                kCTFontAttributeName: font,
                kCTForegroundColorFromContextAttributeName: kCFBooleanTrue!,
            ] as CFDictionary
            let s = CFAttributedStringCreate(nil, visible as CFString, attrs)!
            return CTLineCreateWithAttributedString(s)
        }
        var maxW: CGFloat = 0
        for ctline in contentLines {
            guard let ctline else { continue }
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(ctline, &a, &d, &l))
            if w > maxW { maxW = w }
        }
        maxContentLineWidth = maxW
        invalidateIntrinsicContentSize()
        updateSelectionOverlay()
        needsDisplay = true
    }

    // MARK: - Intrinsic size

    override var intrinsicContentSize: NSSize {
        let h = CGFloat(rows.count) * lineHeight
        let w = textStartX + ceil(maxContentLineWidth) + Self.textInsetRight
        return NSSize(width: w, height: h)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Glyphs draw the right way up in a flipped view by inverting the text matrix.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let firstRow = max(0, Int(floor(dirtyRect.minY / lineHeight)))
        let lastRow = min(rows.count - 1, Int(floor((dirtyRect.maxY - 0.001) / lineHeight)))
        guard firstRow <= lastRow else { return }

        // Order: row backgrounds → selection fill → text/markers/gutters. Selection layers
        // over the row tint but under the glyphs so the text stays readable inside the highlight.
        for i in firstRow...lastRow { drawRowBackground(i, in: ctx) }
        drawSelection(in: ctx, dirtyRect: dirtyRect)
        for i in firstRow...lastRow { drawRowForeground(i, in: ctx) }
    }

    private func drawRowBackground(_ i: Int, in ctx: CGContext) {
        let bg = background(for: rows[i].line)
        guard bg != .clear else { return }
        let yTop = CGFloat(i) * lineHeight
        let rect = NSRect(x: 0, y: yTop, width: self.bounds.width, height: lineHeight)
        ctx.saveGState()
        ctx.setFillColor(bg.cgColor(for: effectiveAppearance))
        ctx.fill(rect)
        ctx.restoreGState()
    }

    private func drawRowForeground(_ i: Int, in ctx: CGContext) {
        let row = rows[i]
        let yTop = CGFloat(i) * lineHeight

        let baseline = yTop + ascent + (lineHeight - ascent - descent) / 2

        // Gutters.
        switch columnLayout {
        case .unified:
            drawGutter(text: row.oldNumber.map(String.init) ?? "",
                       in: NSRect(x: 0, y: yTop, width: oldGutterWidth, height: lineHeight),
                       baseline: baseline, ctx: ctx)
            drawGutter(text: row.newNumber.map(String.init) ?? "",
                       in: NSRect(x: oldGutterWidth, y: yTop,
                                  width: newGutterWidth, height: lineHeight),
                       baseline: baseline, ctx: ctx)
        case .sideBySide(let side, _):
            let n = (side == .left ? row.oldNumber : row.newNumber).map(String.init) ?? ""
            drawGutter(text: n,
                       in: NSRect(x: 0, y: yTop, width: newGutterWidth, height: lineHeight),
                       baseline: baseline, ctx: ctx)
        }

        // Marker (unified only).
        if hasMarkerColumn, let line = row.line {
            let marker: CTLine?
            let color: NSColor
            switch line.kind {
            case .added:   marker = addedMarkerLine;   color = Theme.Color.addedText
            case .removed: marker = removedMarkerLine; color = Theme.Color.removedText
            case .context: marker = contextMarkerLine; color = .secondaryLabelColor
            }
            if let marker {
                ctx.saveGState()
                ctx.setFillColor(color.cgColor(for: effectiveAppearance))
                ctx.textPosition = CGPoint(x: oldGutterWidth + newGutterWidth, y: baseline)
                CTLineDraw(marker, ctx)
                ctx.restoreGState()
            }
        }

        // Content text.
        if let ctline = contentLines[i], let line = row.line {
            ctx.saveGState()
            ctx.setFillColor(textColor(for: line).cgColor(for: effectiveAppearance))
            ctx.textPosition = CGPoint(x: textStartX, y: baseline)
            CTLineDraw(ctline, ctx)
            ctx.restoreGState()
        }
    }

    private func drawGutter(text: String, in rect: NSRect, baseline: CGFloat, ctx: CGContext) {
        guard !text.isEmpty else { return }
        let attrs: CFDictionary = [
            kCTFontAttributeName: gutterFont,
            kCTForegroundColorFromContextAttributeName: kCFBooleanTrue!,
        ] as CFDictionary
        let s = CFAttributedStringCreate(nil, text as CFString, attrs)!
        let ctline = CTLineCreateWithAttributedString(s)
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(ctline, &a, &d, &l))
        let x = rect.maxX - Self.gutterInsetRight - w
        // Gutter sits slightly above the content baseline because it uses a smaller font.
        let gutterBaseline = rect.minY + (rect.height + a - d) / 2
        ctx.saveGState()
        ctx.setFillColor(NSColor.tertiaryLabelColor.cgColor(for: effectiveAppearance))
        ctx.textPosition = CGPoint(x: x, y: gutterBaseline)
        CTLineDraw(ctline, ctx)
        ctx.restoreGState()
    }

    private func background(for line: DiffLine?) -> NSColor {
        guard let line, line.change == .substantive else { return .clear }
        switch line.kind {
        case .added:   return Theme.Color.addedBackground
        case .removed: return Theme.Color.removedBackground
        case .context: return .clear
        }
    }

    private func textColor(for line: DiffLine) -> NSColor {
        if line.change != .substantive { return .tertiaryLabelColor }
        switch line.kind {
        case .added:   return Theme.Color.addedText
        case .removed: return Theme.Color.removedText
        case .context: return .labelColor
        }
    }

    // MARK: - Hit testing

    /// Where a mouse point lands within the view.
    private enum Region { case before, gutter, text(charIndex: Int), past }

    private struct Hit {
        let row: Int
        let region: Region
    }

    private func hit(at point: NSPoint) -> Hit? {
        guard !rows.isEmpty else { return nil }
        let row = min(max(0, Int(floor(point.y / lineHeight))), rows.count - 1)
        if point.x < 0 { return Hit(row: row, region: .before) }
        if point.x < textStartX - 1 { return Hit(row: row, region: .gutter) }
        // Compute character index inside the content line.
        let xInText = point.x - textStartX
        guard let ctline = contentLines[row] else {
            return Hit(row: row, region: .text(charIndex: 0))
        }
        let idx = CTLineGetStringIndexForPosition(ctline, CGPoint(x: max(0, xInText), y: 0))
        if idx == kCFNotFound { return Hit(row: row, region: .past) }
        // CTLine indices are relative to the *rendered* string (tabs expanded to 4 spaces).
        // Map back to the source string so copy yields original tabs.
        let mappedChar = mapRenderedIndexToSource(row: row, renderedIndex: Int(idx))
        return Hit(row: row, region: .text(charIndex: mappedChar))
    }

    /// We render tabs as four spaces but keep `DiffLine.text` as-is for copy fidelity.
    /// Translate a character index from the rendered (tab-expanded) coordinate space back
    /// to the source string's coordinate space.
    private func mapRenderedIndexToSource(row: Int, renderedIndex: Int) -> Int {
        guard let line = rows[row].line else { return 0 }
        var renderedCount = 0
        var sourceCount = 0
        for ch in line.text {
            if renderedCount >= renderedIndex { return sourceCount }
            if ch == "\t" { renderedCount += 4 } else { renderedCount += 1 }
            sourceCount += 1
        }
        return sourceCount
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        let textRect = NSRect(x: textStartX, y: 0,
                              width: max(0, bounds.width - textStartX),
                              height: bounds.height)
        addCursorRect(textRect, cursor: .iBeam)
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        guard !rows.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = hit(at: p) else { return }

        let shift = event.modifierFlags.contains(.shift)
        let cmd = event.modifierFlags.contains(.command)

        // Tell the coordinator a fresh selection is starting (so it can clear other hunks).
        // Shift-extend keeps any existing selection; cmd-toggle keeps line selection across clicks.
        if !shift && !cmd {
            delegate?.contentViewWillBeginSelection(self)
        }
        window?.makeFirstResponder(self)

        switch hit.region {
        case .before, .past:
            // Click in the dead zone — start text mode at the row's natural edge.
            startTextSelection(row: hit.row, char: 0, event: event, shift: shift)
        case .gutter:
            startLineSelection(row: hit.row, event: event, shift: shift, cmd: cmd)
        case .text(let char):
            if event.clickCount >= 3 {
                // Triple-click selects the whole line's text.
                let len = rows[hit.row].line?.text.count ?? 0
                selection = .text(startRow: hit.row, startChar: 0,
                                  endRow: hit.row, endChar: len)
                dragMode = .text(anchorRow: hit.row, anchorChar: 0, granularity: .line)
            } else if event.clickCount == 2 {
                // Double-click selects the word under the cursor.
                let (lo, hi) = wordRange(row: hit.row, around: char)
                selection = .text(startRow: hit.row, startChar: lo, endRow: hit.row, endChar: hi)
                dragMode = .text(anchorRow: hit.row, anchorChar: lo, granularity: .word)
            } else {
                startTextSelection(row: hit.row, char: char, event: event, shift: shift)
            }
        }
        delegate?.contentViewDidChangeSelection(self)
    }

    override func mouseDragged(with event: NSEvent) {
        if case .none = dragMode { return }
        extendDrag(with: event)
    }

    private func extendDrag(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // If the drag has left this view vertically, ask the coordinator to take over.
        if p.y < 0 || p.y > bounds.height {
            if delegate?.contentView(self, didDragOutsideTo: event.locationInWindow) == true {
                autoscroll(with: event)
                return
            }
        }
        guard let hit = hit(at: p) else { return }
        switch dragMode {
        case .none:
            break
        case .text(let aRow, let aChar, let granularity):
            let focusChar: Int
            switch hit.region {
            case .text(let c): focusChar = c
            case .past:        focusChar = rows[hit.row].line?.text.count ?? 0
            case .gutter, .before: focusChar = 0
            }
            extendText(anchorRow: aRow, anchorChar: aChar,
                       focusRow: hit.row, focusChar: focusChar,
                       granularity: granularity)
        case .lines(let aRow, let baseline, let op):
            extendLines(anchor: aRow, focus: hit.row, baseline: baseline, op: op)
        }
        autoscroll(with: event)
        delegate?.contentViewDidChangeSelection(self)
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = .none
        delegate?.contentViewDidChangeSelection(self)
    }

    // MARK: - Selection helpers

    private func startTextSelection(row: Int, char: Int, event: NSEvent, shift: Bool) {
        if shift, case .text(let sR, let sC, _, _) = selection {
            // Shift-click extends from the existing anchor.
            extendText(anchorRow: sR, anchorChar: sC, focusRow: row, focusChar: char,
                       granularity: .character)
            dragMode = .text(anchorRow: sR, anchorChar: sC, granularity: .character)
        } else {
            selection = .text(startRow: row, startChar: char, endRow: row, endChar: char)
            dragMode = .text(anchorRow: row, anchorChar: char, granularity: .character)
        }
    }

    private func startLineSelection(row: Int, event: NSEvent, shift: Bool, cmd: Bool) {
        let current: IndexSet = {
            if case .lines(let s) = selection { return s }
            return IndexSet()
        }()
        let op: DragMode.LineOp = cmd ? .toggle : (shift && !current.isEmpty ? .extend : .replace)
        var baseline = current
        if op == .replace { baseline = IndexSet() }
        var newSet = baseline
        switch op {
        case .replace:
            newSet.insert(row)
        case .extend:
            let firstIndex = current.first ?? row
            let lastIndex = current.last ?? row
            if row > lastIndex { newSet.insert(integersIn: lastIndex...row) }
            else if row < firstIndex { newSet.insert(integersIn: row...firstIndex) }
            else { newSet.insert(row) }
        case .toggle:
            if newSet.contains(row) { newSet.remove(row) } else { newSet.insert(row) }
        }
        selection = .lines(newSet)
        dragMode = .lines(anchorRow: row, baseline: baseline, op: op)
    }

    private func extendText(anchorRow: Int, anchorChar: Int,
                            focusRow: Int, focusChar: Int,
                            granularity: DragMode.Granularity) {
        let (sR, sC, eR, eC): (Int, Int, Int, Int)
        if (focusRow, focusChar) < (anchorRow, anchorChar) {
            (sR, sC, eR, eC) = (focusRow, focusChar, anchorRow, anchorChar)
        } else {
            (sR, sC, eR, eC) = (anchorRow, anchorChar, focusRow, focusChar)
        }
        switch granularity {
        case .character:
            selection = .text(startRow: sR, startChar: sC, endRow: eR, endChar: eC)
        case .word:
            let (lo, _) = wordRange(row: sR, around: sC)
            let (_, hi) = wordRange(row: eR, around: max(0, eC - 1))
            selection = .text(startRow: sR, startChar: lo, endRow: eR, endChar: hi)
        case .line:
            let endLen = rows[eR].line?.text.count ?? 0
            selection = .text(startRow: sR, startChar: 0, endRow: eR, endChar: endLen)
        }
    }

    private func extendLines(anchor: Int, focus: Int, baseline: IndexSet, op: DragMode.LineOp) {
        var s = baseline
        let lo = min(anchor, focus), hi = max(anchor, focus)
        switch op {
        case .replace, .extend:
            s.insert(integersIn: lo...hi)
        case .toggle:
            for r in lo...hi {
                if baseline.contains(r) { s.remove(r) } else { s.insert(r) }
            }
        }
        selection = .lines(s)
    }

    private func wordRange(row: Int, around char: Int) -> (Int, Int) {
        guard let text = rows[row].line?.text, !text.isEmpty else { return (0, 0) }
        let count = text.count
        let clamped = max(0, min(char, count - 1))
        var lo = clamped, hi = clamped
        let chars = Array(text)
        while lo > 0 && isWordChar(chars[lo - 1]) { lo -= 1 }
        while hi < count && isWordChar(chars[hi]) { hi += 1 }
        if lo == hi {
            // Whitespace click — select just that character.
            return (clamped, min(clamped + 1, count))
        }
        return (lo, hi)
    }

    private func isWordChar(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber { return true }
        return c == "_"
    }

    // MARK: - Selection drawing

    private var selectionFillColor: NSColor {
        let isKey = (window?.isKeyWindow == true) && (window?.firstResponder === self)
        return isKey ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
    }

    /// The union of every row band touched by the current selection — used to bound
    /// `setNeedsDisplay` so we don't repaint the whole view on every drag tick.
    private var selectionBounds: NSRect {
        selectionRects.reduce(NSRect.null) { $0.union($1) }
    }

    private func updateSelectionOverlay() {
        let previous = selectionBounds
        selectionRects = computeSelectionRects()
        let combined = previous.union(selectionBounds).insetBy(dx: -1, dy: -1)
        if !combined.isNull && !combined.isEmpty {
            setNeedsDisplay(combined)
        } else {
            needsDisplay = true
        }
    }

    private func computeSelectionRects() -> [NSRect] {
        switch selection {
        case .none:
            return []
        case .text(let sR, let sC, let eR, let eC):
            guard sR <= eR else { return [] }
            var rects: [NSRect] = []
            for r in sR...eR {
                let startC = (r == sR) ? sC : 0
                let endC = (r == eR) ? eC : (rows[r].line?.text.count ?? 0)
                let xLo = xOffset(row: r, sourceChar: startC)
                let xHi: CGFloat
                if r < eR {
                    // Extend trailing edge to the right margin so multi-row selections read as
                    // one continuous block (matches NSTextView).
                    xHi = max(xOffset(row: r, sourceChar: endC),
                              textStartX + ceil(maxContentLineWidth))
                } else {
                    xHi = xOffset(row: r, sourceChar: endC)
                }
                rects.append(NSRect(x: xLo, y: CGFloat(r) * lineHeight,
                                    width: max(0, xHi - xLo), height: lineHeight))
            }
            return rects
        case .lines(let set):
            return set.map {
                NSRect(x: 0, y: CGFloat($0) * lineHeight,
                       width: bounds.width, height: lineHeight)
            }
        }
    }

    private func drawSelection(in ctx: CGContext, dirtyRect: NSRect) {
        guard !selectionRects.isEmpty else { return }
        ctx.saveGState()
        ctx.setFillColor(selectionFillColor.cgColor(for: effectiveAppearance))
        for rect in selectionRects where rect.intersects(dirtyRect) {
            ctx.fill(rect)
        }
        ctx.restoreGState()
    }

    /// Convert a source-string char index to a pixel X within the view.
    private func xOffset(row: Int, sourceChar: Int) -> CGFloat {
        guard let ctline = contentLines[row], let text = rows[row].line?.text else {
            return textStartX
        }
        // Translate source index → rendered index (tabs are 4 spaces in the CTLine).
        var rendered = 0
        var i = 0
        for ch in text {
            if i >= sourceChar { break }
            rendered += (ch == "\t") ? 4 : 1
            i += 1
        }
        let x = CTLineGetOffsetForStringIndex(ctline, CFIndex(rendered), nil)
        return textStartX + x
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification,
                                                  object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification,
                                                  object: nil)
        if let w = window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyDidChange),
                                                   name: NSWindow.didBecomeKeyNotification, object: w)
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyDidChange),
                                                   name: NSWindow.didResignKeyNotification, object: w)
        }
    }

    @objc private func windowKeyDidChange() {
        if !selectionRects.isEmpty { setNeedsDisplay(selectionBounds.insetBy(dx: -1, dy: -1)) }
    }

    // MARK: - Copy

    /// The selected text from this view alone, with markers and line numbers stripped.
    /// Returns `nil` if there is no selection. Used by the coordinator to concatenate across
    /// hunks when a selection spans more than one.
    func selectedText() -> String? {
        switch selection {
        case .none:
            return nil
        case .text(let sR, let sC, let eR, let eC):
            if sR == eR {
                guard let t = rows[sR].line?.text else { return "" }
                return substring(t, from: sC, to: eC)
            }
            var parts: [String] = []
            for r in sR...eR {
                let t = rows[r].line?.text ?? ""
                if r == sR { parts.append(substring(t, from: sC, to: t.count)) }
                else if r == eR { parts.append(substring(t, from: 0, to: eC)) }
                else { parts.append(t) }
            }
            return parts.joined(separator: "\n")
        case .lines(let set):
            var parts: [String] = []
            for r in set.sorted() {
                guard let t = rows[r].line?.text else { continue }
                parts.append(t)
            }
            return parts.joined(separator: "\n")
        }
    }

    private func substring(_ s: String, from lo: Int, to hi: Int) -> String {
        let lo = max(0, min(lo, s.count))
        let hi = max(lo, min(hi, s.count))
        let start = s.index(s.startIndex, offsetBy: lo)
        let end = s.index(s.startIndex, offsetBy: hi)
        return String(s[start..<end])
    }

    @objc func copy(_ sender: Any?) {
        // Coordinator gets first dibs so multi-hunk selections copy as one string.
        let text = delegate?.combinedCopyText(forActive: self) ?? selectedText()
        guard let text, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Standard Cmd-A: select every row of this hunk's text. The coordinator clears other
    /// hunks first so the visual state matches what `copy:` will return.
    @objc override func selectAll(_ sender: Any?) {
        guard !rows.isEmpty else { return }
        delegate?.contentViewWillBeginSelection(self)
        window?.makeFirstResponder(self)
        let lastRow = rows.count - 1
        let lastChar = rows[lastRow].line?.text.count ?? 0
        selection = .text(startRow: 0, startChar: 0, endRow: lastRow, endChar: lastChar)
        delegate?.contentViewDidChangeSelection(self)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            if let combined = delegate?.combinedCopyText(forActive: self) {
                return !combined.isEmpty
            }
            return !selection.isEmpty
        case #selector(selectAll(_:)):
            return !rows.isEmpty
        default:
            return true
        }
    }

    // MARK: - Context menu

    /// Right-click menu — matches what users expect from any selectable native text view.
    override func menu(for event: NSEvent) -> NSMenu? {
        // If there's no selection under the cursor, place caret-style selection at the click
        // first so Copy / Look Up apply to *something* (NSTextView does the same — right-click
        // in an empty area selects the word under the pointer).
        if selection.isEmpty {
            let p = convert(event.locationInWindow, from: nil)
            if let hit = hit(at: p), case .text(let c) = hit.region {
                let (lo, hi) = wordRange(row: hit.row, around: c)
                if lo != hi {
                    delegate?.contentViewWillBeginSelection(self)
                    window?.makeFirstResponder(self)
                    selection = .text(startRow: hit.row, startChar: lo,
                                      endRow: hit.row, endChar: hi)
                    delegate?.contentViewDidChangeSelection(self)
                }
            }
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        // The Services submenu auto-populates from the system based on `writeSelection(to:types:)`
        // and `validRequestor(forSendType:returnType:)` below — Look Up, Translate, Share, etc.
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSApp.servicesMenu
        menu.addItem(services)
        return menu
    }

    // MARK: - Services menu integration

    /// Tell the Services system this view can supply selected text to other services
    /// (Look Up, Translate, Share, custom Automator services, etc.). The view never accepts
    /// data back — it's read-only — so `returnType` is always nil.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, sendType == .string, !selection.isEmpty {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard,
                        types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string) else { return false }
        let text = delegate?.combinedCopyText(forActive: self) ?? selectedText()
        guard let text, !text.isEmpty else { return false }
        pboard.declareTypes([.string], owner: nil)
        pboard.setString(text, forType: .string)
        return true
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        switch columnLayout {
        case .unified: return "Diff hunk"
        case .sideBySide(let side, _): return "Diff hunk \(side == .left ? "before" : "after")"
        }
    }
    override func accessibilityChildren() -> [Any]? {
        rows.enumerated().compactMap { i, row -> NSAccessibilityElement? in
            guard let line = row.line else { return nil }
            let el = NSAccessibilityElement.element(
                withRole: .staticText,
                frame: NSRect(x: 0, y: CGFloat(i) * lineHeight,
                              width: bounds.width, height: lineHeight),
                label: nil, parent: self) as? NSAccessibilityElement
            el?.setAccessibilityValue(line.text)
            let kind: String
            switch line.kind { case .added: kind = "added"; case .removed: kind = "removed"; case .context: kind = "context" }
            el?.setAccessibilityLabel("\(kind) line")
            return el
        }
    }
}

// MARK: - NSTextInputClient

/// Minimal `NSTextInputClient` conformance — gives us free dictation indicator placement
/// and accessibility-driven selection introspection. We don't accept text input (read-only),
/// so the write/delete/markedText methods are no-ops.
extension DiffHunkContentView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {}
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange {
        // We expose selection as if the whole hunk were one string (rows joined by "\n").
        // This is enough for first-rect / dictation positioning.
        switch selection {
        case .none:
            return NSRange(location: NSNotFound, length: 0)
        case .text(let sR, let sC, let eR, let eC):
            let start = flatten(row: sR, char: sC)
            let end = flatten(row: eR, char: eC)
            return NSRange(location: start, length: end - start)
        case .lines(let set):
            guard let first = set.first, let last = set.last else {
                return NSRange(location: NSNotFound, length: 0)
            }
            let start = flatten(row: first, char: 0)
            let endLen = rows[last].line?.text.count ?? 0
            let end = flatten(row: last, char: endLen)
            return NSRange(location: start, length: end - start)
        }
    }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect {
        guard let (row, char) = unflatten(range.location), let window else { return .zero }
        let xLo = xOffset(row: row, sourceChar: char)
        let endChar = char + range.length
        let xHi = xOffset(row: row, sourceChar: min(endChar, rows[row].line?.text.count ?? char))
        let local = NSRect(x: xLo, y: CGFloat(row) * lineHeight,
                           width: max(1, xHi - xLo), height: lineHeight)
        let windowRect = convert(local, to: nil)
        return window.convertToScreen(windowRect)
    }
    func characterIndex(for point: NSPoint) -> Int {
        let local = convert(point, from: nil)
        guard let h = hit(at: local), case .text(let c) = h.region else { return NSNotFound }
        return flatten(row: h.row, char: c)
    }

    private func flatten(row: Int, char: Int) -> Int {
        var pos = 0
        for r in 0..<min(row, rows.count) {
            pos += (rows[r].line?.text.count ?? 0) + 1
        }
        return pos + char
    }
    private func unflatten(_ pos: Int) -> (Int, Int)? {
        var p = pos
        for (i, row) in rows.enumerated() {
            let len = (row.line?.text.count ?? 0) + 1
            if p < len { return (i, min(p, len - 1)) }
            p -= len
        }
        return nil
    }
}

// MARK: - NSColor appearance helper

private extension NSColor {
    /// Resolve a (possibly dynamic) `NSColor` against an appearance and hand back a `CGColor`.
    /// Necessary because `CGColor` itself is appearance-static — calling `.cgColor` on a dynamic
    /// `NSColor` snapshots whatever appearance happens to be current at call time.
    func cgColor(for appearance: NSAppearance) -> CGColor {
        var result: CGColor = .clear
        appearance.performAsCurrentDrawingAppearance {
            result = self.cgColor
        }
        return result
    }
}

// MARK: - Cross-hunk selection coordinator

/// Coordinates selection across all `DiffHunkContentView`s that belong to the same diff.
/// Each view owns its own local selection rendering; the coordinator clears siblings when a
/// new selection begins and extends the active selection into adjacent views when a drag
/// crosses hunk boundaries.
final class DiffSelectionCoordinator: NSObject, DiffHunkContentViewDelegate {

    /// Views in display order (top to bottom). Reassigned every time the controller rebuilds
    /// hunks.
    var views: [DiffHunkContentView] = [] {
        didSet { oldValue.forEach { if $0.delegate === self { $0.delegate = nil } }
                views.forEach { $0.delegate = self } }
    }

    /// The view that started the current text-mode selection. Cross-hunk extension preserves
    /// its anchor and updates the focus end as the drag enters other views.
    private weak var anchorView: DiffHunkContentView?
    private var anchorRow: Int = 0
    private var anchorChar: Int = 0

    func contentViewWillBeginSelection(_ view: DiffHunkContentView) {
        for v in views where v !== view { v.selection = .none }
        anchorView = view
        // Snapshot the anchor at start. Updated below when the mouseDown completes.
        if case .text(let sR, let sC, _, _) = view.selection {
            anchorRow = sR; anchorChar = sC
        }
    }

    func contentViewDidChangeSelection(_ view: DiffHunkContentView) {
        if view === anchorView, case .text(let sR, let sC, _, _) = view.selection {
            // Track the anchor as it stabilises after the initial mouseDown.
            anchorRow = sR; anchorChar = sC
        }
    }

    func contentView(_ view: DiffHunkContentView,
                     didDragOutsideTo pointInWindow: NSPoint) -> Bool {
        guard let anchor = anchorView else { return false }
        // Find the view under the current mouse position.
        guard let target = viewUnder(pointInWindow: pointInWindow) else { return false }
        let local = target.convert(pointInWindow, from: nil)
        let targetRow = max(0, min(target.rows.count - 1,
                                   Int(floor(local.y / Theme.Metric.diffLineHeight))))
        let targetChar = target.rows[targetRow].line?.text.count ?? 0

        // Decide direction relative to the anchor view's screen position.
        let anchorIndex = views.firstIndex(where: { $0 === anchor }) ?? 0
        let targetIndex = views.firstIndex(where: { $0 === target }) ?? anchorIndex

        if targetIndex == anchorIndex {
            // Same view — no cross-hunk extension needed; let the view handle it.
            return false
        }

        // Build a multi-view selection: the anchor view extends to its first/last row,
        // every intermediate view selects all rows, the target view extends from its
        // edge to (targetRow, targetChar).
        let goingDown = targetIndex > anchorIndex
        let anchorLastRow = goingDown ? anchor.rows.count - 1 : 0
        let anchorLastChar = goingDown ? (anchor.rows[anchorLastRow].line?.text.count ?? 0) : 0
        anchor.selection = .text(
            startRow: goingDown ? anchorRow : 0,
            startChar: goingDown ? anchorChar : 0,
            endRow: goingDown ? anchorLastRow : anchorRow,
            endChar: goingDown ? anchorLastChar : anchorChar
        )

        let range = goingDown ? (anchorIndex + 1)...targetIndex : targetIndex...(anchorIndex - 1)
        for i in range {
            let v = views[i]
            if v === target {
                if goingDown {
                    v.selection = .text(startRow: 0, startChar: 0,
                                        endRow: targetRow, endChar: targetChar)
                } else {
                    let lastRow = v.rows.count - 1
                    let lastChar = v.rows[lastRow].line?.text.count ?? 0
                    v.selection = .text(startRow: targetRow, startChar: targetChar,
                                        endRow: lastRow, endChar: lastChar)
                }
            } else {
                let lastRow = v.rows.count - 1
                let lastChar = v.rows[lastRow].line?.text.count ?? 0
                v.selection = .text(startRow: 0, startChar: 0,
                                    endRow: lastRow, endChar: lastChar)
            }
        }
        return true
    }

    private func viewUnder(pointInWindow: NSPoint) -> DiffHunkContentView? {
        for v in views {
            let p = v.convert(pointInWindow, from: nil)
            if p.y >= 0 && p.y <= v.bounds.height { return v }
        }
        // If above all views, return the topmost; if below, the bottommost.
        guard let first = views.first, let last = views.last else { return nil }
        let firstWindowOrigin = first.convert(NSPoint.zero, to: nil)
        return pointInWindow.y > firstWindowOrigin.y ? first : last
    }

    /// Build the concatenated copy text across all views that have a selection. Used by the
    /// controller's responder-chain `copy:` override so a multi-hunk selection copies as one
    /// block.
    func combinedSelectedText() -> String? {
        let parts = views.compactMap { $0.selectedText() }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    /// Delegate hook: when only one hunk holds a selection there's nothing to combine, so we
    /// return `nil` and let the view copy its own slice. When two or more do, this is the
    /// joined text in display order.
    func combinedCopyText(forActive view: DiffHunkContentView) -> String? {
        let withSelection = views.filter { !$0.selection.isEmpty }
        guard withSelection.count > 1 else { return nil }
        return combinedSelectedText()
    }

    func clearAll() {
        for v in views { v.selection = .none }
        anchorView = nil
    }
}
