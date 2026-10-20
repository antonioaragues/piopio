import Observation
import Sparkle
import SwiftUI

/// Sparkle 2 updates. Off unless the build sets both SUFeedURL and SUPublicEDKey (release builds; docs/releasing.md).
@Observable @MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private(set) var canCheck = false

    var isConfigured: Bool { controller != nil }

    var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var checksAutomatically: Bool {
        get { _ = canCheck; return controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; canCheck = controller?.updater.canCheckForUpdates ?? false }
    }

    private init() {
        let info = Bundle.main.infoDictionary
        let feed = info?["SUFeedURL"] as? String ?? ""
        let key = info?["SUPublicEDKey"] as? String ?? ""
        guard !feed.isEmpty, !key.isEmpty else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Debug automation: download in the background and install on quit, with no UI.
    func installSilently() {
        controller?.updater.automaticallyDownloadsUpdates = true
        controller?.updater.checkForUpdatesInBackground()
    }
}

/// "Check for Updates…" in the app menu.
struct CheckForUpdatesButton: View {
    private let updater = AppUpdater.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
    }
}
