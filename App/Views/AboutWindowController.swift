import AppKit

/// The About window: the four architecture layers as periodic-table tiles, then a short list of
/// things the app deliberately doesn't do.
final class AboutWindowController: NSWindowController {
    private static let width: CGFloat = 460
    private static let repoURL = URL(string: "https://github.com/jasoncabot/elemental")!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "About Elemental"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    private struct Layer {
        let number: Int, symbol: String, name: String, detail: String, tint: NSColor
    }

    // The four orbs of the app icon, sampled from it: earth, water, fire, air.
    private static let earth = NSColor(srgbRed: 0.28, green: 0.60, blue: 0.40, alpha: 1)
    private static let water = NSColor(srgbRed: 0.16, green: 0.43, blue: 0.75, alpha: 1)
    private static let fire = NSColor(srgbRed: 0.95, green: 0.36, blue: 0.16, alpha: 1)
    private static let air = NSColor(srgbRed: 0.58, green: 0.69, blue: 0.78, alpha: 1)

    /// Mirrors the layer table in the architecture docs; each layer only knows the one before it.
    private static let layers: [Layer] = [
        Layer(number: 1, symbol: "Gd", name: "Data", detail: "Reads git", tint: Self.earth),
        Layer(number: 2, symbol: "Pr", name: "Presenters", detail: "Holds state", tint: Self.water),
        Layer(number: 3, symbol: "Vw", name: "Views", detail: "Draws it", tint: Self.fire),
        Layer(number: 4, symbol: "Co", name: "Coordinator", detail: "Wires it up", tint: Self.air),
    ]

    private static let promises: [(symbol: String, title: String, detail: String)] = [
        ("lock.fill", "Read-only", "It never changes your repository."),
        ("wifi.slash", "Fully offline", "Nothing leaves your Mac. Update checks are opt-in."),
        ("bolt.fill", "No AI needed", "Diffs open straight away, with no model involved."),
        ("person.crop.circle.badge.xmark", "No account", "No sign-in and no server."),
    ]

    private func makeContent() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("Elemental")

        let name = NSTextField(labelWithString: "Elemental")
        name.font = .systemFont(ofSize: 26, weight: .bold)

        let tagline = NSTextField(labelWithString: "A git client for reading changes.")
        tagline.font = .systemFont(ofSize: 13)
        tagline.textColor = .secondaryLabelColor

        let version = NSTextField(labelWithString: Self.versionString())
        version.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        version.textColor = .tertiaryLabelColor

        let tiles = NSStackView(views: Self.layers.map {
            ElementTileView(number: $0.number, symbol: $0.symbol, name: $0.name,
                            detail: $0.detail, tint: $0.tint)
        })
        tiles.orientation = .horizontal
        tiles.distribution = .fillEqually
        tiles.spacing = 8

        let layersCaption = caption("Each layer only talks to the one before it.")

        let promiseRows = NSStackView(views: Self.promises.map(makePromiseRow))
        promiseRows.orientation = .vertical
        promiseRows.alignment = .leading
        promiseRows.spacing = 10

        let github = NSButton(title: "View on GitHub", target: self, action: #selector(openRepository(_:)))
        github.bezelStyle = .rounded
        github.controlSize = .small

        let stack = NSStackView(views: [
            icon, name, tagline, version,
            sectionHeader("How it's built"), tiles, layersCaption,
            sectionHeader("What it doesn't do"), promiseRows,
            github,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(2, after: name)
        stack.setCustomSpacing(24, after: version)
        stack.setCustomSpacing(10, after: tiles)
        stack.setCustomSpacing(24, after: layersCaption)
        stack.setCustomSpacing(22, after: promiseRows)
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        background.addSubview(stack)

        let inner = Self.width - 48
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor).id("About.stack.top"),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor).id("About.stack.leading"),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor).id("About.stack.trailing"),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor).id("About.stack.bottom"),
            background.widthAnchor.constraint(equalToConstant: Self.width).id("About.content.width"),
            icon.widthAnchor.constraint(equalToConstant: 88).id("About.icon.width"),
            icon.heightAnchor.constraint(equalToConstant: 88).id("About.icon.height"),
            tiles.widthAnchor.constraint(equalToConstant: inner).id("About.tiles.width"),
            layersCaption.widthAnchor.constraint(equalToConstant: inner).id("About.layersCaption.width"),
            promiseRows.widthAnchor.constraint(equalToConstant: inner).id("About.promises.width"),
        ])
        return background
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.preferredMaxLayoutWidth = Self.width - 48
        return label
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func makePromiseRow(_ promise: (symbol: String, title: String, detail: String)) -> NSView {
        let image = NSImage(systemSymbolName: promise.symbol, accessibilityDescription: nil)
        let glyph = NSImageView(image: image ?? NSImage())
        glyph.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        glyph.contentTintColor = .secondaryLabelColor
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: promise.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: promise.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = Self.width - 48 - 36

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [glyph, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        glyph.widthAnchor.constraint(equalToConstant: 24).id("About.promise.glyph.width").isActive = true
        return row
    }

    private static func versionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        return "Version \(version)"
    }

    @objc private func openRepository(_ sender: Any?) {
        NSWorkspace.shared.open(Self.repoURL)
    }
}

/// One periodic-table-style tile: number, symbol, name and a short gloss, in the layer's tint.
@objc(ElementTileView)
private final class ElementTileView: NSView {
    private let tint: NSColor

    init(number: Int, symbol: String, name: String, detail: String, tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5

        let ink = NSColor(name: nil) { appearance in
            let resolved = tint.resolvedColor(for: appearance)
            let label = NSColor.labelColor.resolvedColor(for: appearance)
            return resolved.blended(withFraction: 0.45, of: label) ?? resolved
        }

        let numberLabel = NSTextField(labelWithString: String(number))
        numberLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        numberLabel.textColor = ink.withAlphaComponent(0.8)

        let symbolLabel = NSTextField(labelWithString: symbol)
        let base = NSFont.systemFont(ofSize: 32, weight: .semibold)
        symbolLabel.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 32) } ?? base
        symbolLabel.textColor = ink

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let column = NSStackView(views: [numberLabel, symbolLabel, nameLabel, detailLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.setCustomSpacing(2, after: symbolLabel)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8).id("ElementTile.column.top"),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10).id("ElementTile.column.bottom"),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10).id("ElementTile.column.leading"),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).id("ElementTile.column.trailing"),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(name): \(detail)")
        toolTip = "\(name) — \(detail)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint.withAlphaComponent(0.13).cgColor
            layer?.borderColor = tint.withAlphaComponent(0.35).cgColor
        }
    }
}
