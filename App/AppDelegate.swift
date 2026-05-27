import AppKit
import GitData

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMainMenu()

        // Build the singleton data-layer objects.
        // GitService (built by another agent) is not available on this branch;
        // we wire directly to CLIGitBackend + FSEventsRepoWatcher against the
        // GitBackend / RepoWatcher protocols so swapping in GitService later is
        // a one-line change in AppDelegate only.
        guard let backend = try? CLIGitBackend() else {
            showFatalAlert(message: "git not found",
                           detail: "Elemental requires git to be installed and on your PATH.")
            return
        }
        let watcher = FSEventsRepoWatcher()

        let c = AppCoordinator(backend: backend, watcher: watcher)
        coordinator = c

        c.windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            await c.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu

    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Elemental",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Repository…",
                         action: #selector(openRepository(_:)),
                         keyEquivalent: "o")
        fileMenuItem.submenu = fileMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc private func openRepository(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a git repository folder"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.coordinator?.addRepository(at: url) }
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
