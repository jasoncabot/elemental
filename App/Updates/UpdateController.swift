import AppKit
import Sparkle

/// Owns the Sparkle updater for the app's lifetime.
///
/// Elemental never contacts the network on its own. Info.plist sets `SUEnableAutomaticChecks` to
/// NO, so Sparkle neither checks in the background nor asks "check automatically?" on second
/// launch. The only ways an update check happens are a deliberate **Check for Updates…** or the
/// user turning on automatic checks in Settings. Sparkle persists those choices in user defaults
/// and owns that state; the Settings window binds straight to it.
@MainActor
final class UpdateController {
    /// Target for "Check for Updates…" menu items and buttons. Sparkle validates them itself
    /// (disabled while a check is already running).
    let controller: SPUStandardUpdaterController
    var updater: SPUUpdater { controller.updater }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    static let checkForUpdatesAction = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
}
