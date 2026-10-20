import UIKit

/// Asks iOS for a few extra seconds of execution while a resume is under way, so a suspension that lands between "interruption ended"
/// and the audio session coming back does not strand the microphone. It is not what keeps the app running in the background: the
/// `audio` background mode and a live record session do that.
@MainActor
final class BackgroundGrace {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private let onExpire: @MainActor () -> Void

    init(onExpire: @escaping @MainActor () -> Void) {
        self.onExpire = onExpire
    }

    /// Idempotent: a second `begin` while one is held keeps the first.
    func begin(_ name: String) {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.onExpire()
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
