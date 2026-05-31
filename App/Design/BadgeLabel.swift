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
