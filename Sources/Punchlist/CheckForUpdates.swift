import Combine
import Sparkle
import SwiftUI

/// "Check for Updates…" in the app menu. Sparkle reads the feed URL and the key that
/// signs updates from Info.plist (see bundle.sh), and release.sh publishes the feed.
struct CheckForUpdatesButton: View {
    @StateObject private var model: Model
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _model = StateObject(wrappedValue: Model(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!model.canCheckForUpdates)
    }

    /// Mirrors the updater's KVO property, which is false while a check is already running.
    /// Menu commands don't get view lifecycle events, so this can't be an onReceive.
    @MainActor
    final class Model: ObservableObject {
        @Published var canCheckForUpdates = false

        init(updater: SPUUpdater) {
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        }
    }
}
