import AppKit
import GitData

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinators: [AppCoordinator] = []
    private var backend: CLIGitBackend?
    private var watcher: FSEventsRepoWatcher?
    /// Set by application(_:open:) before the deferred first-window fires, so we skip
    /// opening an empty session-restore window when launched directly via `el <path>`.
    private var openedViaURL = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMainMenu()

        guard let backend = try? CLIGitBackend() else {
            showFatalAlert(message: "git not found",
                           detail: "Elemental requires git to be installed and on your PATH.")
            return
        }
        let watcher = FSEventsRepoWatcher()
        self.backend = backend
        self.watcher = watcher

        // Defer so application(_:open:) can set openedViaURL first when the app is
        // cold-launched with a path argument (e.g. `el /some/repo`).
        DispatchQueue.main.async {
            if !self.openedViaURL {
                self.openNewWindow(restoreSession: true)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        openedViaURL = true
        // Always open a dedicated new window for this invocation.
        openNewWindow(restoreSession: false)
        if let c = coordinators.last {
            urls.forEach { c.addRepository(at: $0) }
        }
    }

    // MARK: - Coordinator management

    private var keyCoordinator: AppCoordinator? {
        let key = NSApp.keyWindow
        return coordinators.first { $0.windowController.window === key }
            ?? coordinators.last
    }

    @discardableResult
    private func makeNewCoordinator() -> AppCoordinator? {
        MainActor.assumeIsolated {
            guard let backend, let watcher else { return nil }
            let c = AppCoordinator(backend: backend, watcher: watcher)
            coordinators.append(c)
            guard let window = c.windowController.window else { return c }
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self, weak c] _ in
                MainActor.assumeIsolated {
                    guard let self, let c else { return }
                    self.coordinators.removeAll { $0 === c }
                }
            }
            return c
        }
    }

    private func openNewWindow(restoreSession: Bool) {
        MainActor.assumeIsolated {
            guard let c = makeNewCoordinator() else { return }
            if let prev = coordinators.dropLast().last?.windowController.window {
                let pt = NSPoint(x: prev.frame.minX + 22, y: prev.frame.maxY - 22)
                c.windowController.window?.setFrameTopLeftPoint(pt)
            }
            c.windowController.showWindow(nil)
            if restoreSession {
                Task { @MainActor in await c.start() }
            }
        }
    }

    // MARK: - Menu

    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Elemental",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Elemental",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window",
                         action: #selector(newWindow(_:)),
                         keyEquivalent: "n")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Open Repository…",
                         action: #selector(openRepository(_:)),
                         keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Remove Repository",
                         action: #selector(removeCurrentRepository(_:)),
                         keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Install Command Line Tool…",
                         action: #selector(installCommandLineTool(_:)),
                         keyEquivalent: "")
        fileMenuItem.submenu = fileMenu

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Increase Font Size",
                         action: #selector(increaseDiffFontSize(_:)),
                         keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Decrease Font Size",
                         action: #selector(decreaseDiffFontSize(_:)),
                         keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Reset Font Size",
                         action: #selector(resetDiffFontSize(_:)),
                         keyEquivalent: "0")
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc private func newWindow(_ sender: Any?) {
        openNewWindow(restoreSession: false)
    }

    @objc private func installCommandLineTool(_ sender: Any?) {
        let script = """
        #!/bin/zsh
        # el - open a directory in Elemental
        # Usage: el [path]   (defaults to current directory)
        path="${1:-.}"
        abs_path=$(cd "$path" 2>/dev/null && pwd)
        if [[ -z "$abs_path" ]]; then
            echo "el: not a directory: $path" >&2
            exit 1
        fi
        /usr/bin/open -a Elemental "$abs_path"
        """

        let fm = FileManager.default
        let binDir = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")
        let destination = (binDir as NSString).appendingPathComponent("el")

        do {
            if !fm.fileExists(atPath: binDir) {
                try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            }
            try script.write(toFile: destination, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination)

            let alert = NSAlert()
            alert.messageText = "Installed"
            alert.informativeText = "Installed 'el' to ~/.local/bin/el. You can now run 'el .' in any terminal to open that directory in Elemental.\n\nMake sure ~/.local/bin is on your PATH."
            alert.alertStyle = .informational
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Installation Failed"
            alert.informativeText = "Could not write to ~/.local/bin/el.\n\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func removeCurrentRepository(_ sender: Any?) {
        Task { @MainActor [weak self] in self?.keyCoordinator?.removeCurrentRepository() }
    }

    @objc private func increaseDiffFontSize(_ sender: Any?) {
        Theme.Font.diffFontSize += 1
    }

    @objc private func decreaseDiffFontSize(_ sender: Any?) {
        Theme.Font.diffFontSize -= 1
    }

    @objc private func resetDiffFontSize(_ sender: Any?) {
        Theme.Font.diffFontSize = Theme.Font.defaultDiffSize
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(removeCurrentRepository(_:)) {
            return MainActor.assumeIsolated { self.keyCoordinator?.activeRepoURL != nil }
        }
        if menuItem.action == #selector(newWindow(_:)) {
            return backend != nil
        }
        if menuItem.action == #selector(increaseDiffFontSize(_:)) {
            return Theme.Font.diffFontSize < Theme.Font.maxDiffSize
        }
        if menuItem.action == #selector(decreaseDiffFontSize(_:)) {
            return Theme.Font.diffFontSize > Theme.Font.minDiffSize
        }
        return true
    }

    @objc private func openRepository(_ sender: Any?) {
        let coordinator = keyCoordinator
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a git repository folder"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if let coordinator {
                    coordinator.addRepository(at: url)
                } else {
                    self?.openNewWindow(restoreSession: false)
                    self?.keyCoordinator?.addRepository(at: url)
                }
            }
        }
        if let window = coordinator?.windowController.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    // MARK: - Error

    private func showFatalAlert(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}
