import AppKit
import Sparkle

/// The app's Settings window (⌘,). One section today — Software Update — bound directly to
/// Sparkle's own persisted preferences, so the checkboxes and Sparkle can never disagree.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let updates: UpdateController
    private let lastCheckedLabel = NSTextField(labelWithString: "")

    private static let width: CGFloat = 460

    init(updates: UpdateController) {
        self.updates = updates
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeContent() -> NSView {
        let updater = updates.updater

        let heading = NSTextField(labelWithString: "Software Update")
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        let autoCheck = NSButton(checkboxWithTitle: "Automatically check for updates",
                                 target: nil, action: nil)
        autoCheck.bind(.value, to: updater, withKeyPath: "automaticallyChecksForUpdates")

        // Only meaningful once automatic checks are on, as in System Settings' Software Update.
        let autoDownload = NSButton(checkboxWithTitle: "Automatically download and install updates",
                                    target: nil, action: nil)
        autoDownload.bind(.value, to: updater, withKeyPath: "automaticallyDownloadsUpdates")
        autoDownload.bind(.enabled, to: updater, withKeyPath: "automaticallyChecksForUpdates")

        let explanation = NSTextField(wrappingLabelWithString:
            "Elemental only contacts GitHub to look for a newer release when you choose "
            + "Check for Updates… or turn on automatic checks. It sends nothing about you or your repositories.")
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = Self.width - 40 - 20

        lastCheckedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lastCheckedLabel.textColor = .secondaryLabelColor

        let checkNow = NSButton(title: "Check Now", target: updates.controller,
                                action: UpdateController.checkForUpdatesAction)
        checkNow.bind(.enabled, to: updater, withKeyPath: "canCheckForUpdates")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        let footer = NSStackView(views: [lastCheckedLabel, spacer, checkNow])
        footer.orientation = .horizontal
        footer.alignment = .firstBaseline

        let indented = NSStackView(views: [autoDownload])
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        let stack = NSStackView(views: [heading, autoCheck, indented, explanation, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(10, after: heading)
        stack.setCustomSpacing(12, after: indented)
        stack.setCustomSpacing(16, after: explanation)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor).id("Settings.stack.top"),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor).id("Settings.stack.leading"),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor).id("Settings.stack.trailing"),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor).id("Settings.stack.bottom"),
            content.widthAnchor.constraint(equalToConstant: Self.width).id("Settings.content.width"),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)
                .id("Settings.explanation.width"),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)
                .id("Settings.footer.width"),
        ])
        refreshLastChecked()
        return content
    }

    /// Sparkle doesn't announce `lastUpdateCheckDate` changes, so refresh whenever the window is
    /// brought forward (which is also when a finished check's alert hands focus back).
    func windowDidBecomeKey(_ notification: Notification) { refreshLastChecked() }

    private func refreshLastChecked() {
        guard let date = updates.updater.lastUpdateCheckDate else {
            lastCheckedLabel.stringValue = "Last checked: Never"
            return
        }
        lastCheckedLabel.stringValue = "Last checked: "
            + date.formatted(date: .abbreviated, time: .shortened)
    }
}
