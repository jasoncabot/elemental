import AppKit

/// A small rounded pill used for ref names, file signals, and risk markers.
/// Luminous, jewel-like fill with a hairline border — vivid enough to carry semantic meaning
/// without overwhelming the surrounding typography.
@objc(BadgeLabel)
final class BadgeLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private var fillColor: NSColor = .clear
    private var borderColor: NSColor = .clear

    var horizontalInset: CGFloat = 8 { didSet { needsUpdateConstraints = true } }

    init(text: String, tint: NSColor, font: NSFont = Theme.Font.pill, filled: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous

        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.stringValue = text
        // More vivid text: blend tint 42% into labelColor so it reads as coloured text, not grey.
        label.textColor = filled
            ? (tint.blended(withFraction: 0.42, of: .labelColor) ?? tint)
            : tint
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        if filled {
            fillColor = tint.withAlphaComponent(0.16)
            borderColor = tint.withAlphaComponent(0.28)
            layer?.backgroundColor = fillColor.cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = borderColor.cgColor
        } else {
            layer?.borderWidth = 1
            layer?.borderColor = tint.withAlphaComponent(0.45).cgColor
        }

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3)
                .id("BadgeLabel.label.top"),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
                .id("BadgeLabel.label.bottom"),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset)
                .id("BadgeLabel.label.leading").h(),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset)
                .id("BadgeLabel.label.trailing").h(),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = fillColor.cgColor
        layer?.borderColor = borderColor.cgColor
    }
}

/// A `BadgeLabel` that acts as a button — pointing-hand cursor, press dimming, and an accessible
/// press action. Used for chips that open more detail (e.g. a commit note) without looking like
/// a bordered push button in the middle of metadata.
@objc(BadgeButton)
final class BadgeButton: NSView {
    var onPress: ((BadgeButton) -> Void)?
    private let badge: BadgeLabel
    private let text: String

    init(text: String, tint: NSColor, font: NSFont = Theme.Font.pill, filled: Bool = true) {
        self.text = text
        badge = BadgeLabel(text: text, tint: tint, font: font, filled: filled)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor).id("BadgeButton.badge.top"),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor).id("BadgeButton.badge.bottom"),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor).id("BadgeButton.badge.leading"),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor).id("BadgeButton.badge.trailing"),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // The badge's label is an NSTextField that would otherwise swallow the click.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) { badge.alphaValue = 0.6 }

    override func mouseUp(with event: NSEvent) {
        badge.alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?(self) }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityPerformPress() -> Bool { onPress?(self); return true }
}
