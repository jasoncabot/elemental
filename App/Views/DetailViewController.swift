import AppKit

/// Detail pane placeholder — shows commit metadata and will host the diff view in a later phase.
final class DetailViewController: NSViewController {

    private let placeholderLabel = NSTextField(labelWithString: "Select a commit to view details.")

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        placeholderLabel.font = NSFont.systemFont(ofSize: 13)
        placeholderLabel.textColor = .tertiaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        view = container
    }

    /// Called by the coordinator when commit selection changes.
    func showCommit(sha: String?) {
        if let sha {
            placeholderLabel.stringValue = sha
        } else {
            placeholderLabel.stringValue = "Select a commit to view details."
        }
    }
}
