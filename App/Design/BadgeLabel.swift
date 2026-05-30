import AppKit

/// A small rounded pill used for ref names, file signals, and risk markers.
/// Tinted, low-contrast fills keep the UI calm while still reading as semantic.
final class BadgeLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private var fillColor: NSColor = .clear

    var horizontalInset: CGFloat = 6 { didSet { needsUpdateConstraints = true } }

    init(text: String, tint: NSColor, font: NSFont = Theme.Font.pill, filled: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Metric.pillRadius
        layer?.cornerCurve = .continuous

        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.stringValue = text
        label.textColor = filled ? tint.blended(withFraction: 0.55, of: .labelColor) ?? tint : tint
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        fillColor = filled ? tint.withAlphaComponent(0.14) : .clear
        layer?.backgroundColor = fillColor.cgColor
        if !filled {
            layer?.borderWidth = 1
            layer?.borderColor = tint.withAlphaComponent(0.4).cgColor
        }

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2)
                .id("BadgeLabel.label.top"),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
                .id("BadgeLabel.label.bottom"),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset)
                .id("BadgeLabel.label.leading"),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset)
                .id("BadgeLabel.label.trailing"),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        // Keep tints resolved for the current appearance.
        layer?.backgroundColor = fillColor.cgColor
    }
}
