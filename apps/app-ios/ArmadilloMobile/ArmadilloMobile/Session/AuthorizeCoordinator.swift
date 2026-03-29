// STATUS: ACTIVE
// PURPOSE: writes intent.pending flag to App Group UserDefaults when widget FaceID succeeds

import Foundation

enum AuthorizeCoordinator {
    static let suiteName = "group.com.dreiglaser"
    static let pendingKey = "intent.pending.ts"
    static let didReceiveIntent = Notification.Name("SymbiAuth.didReceiveIntent")

    /// Called by the widget's AuthorizeIntent after FaceID passes.
    /// Writes a timestamp flag and posts a notification for PairingViewModel to pick up.
    static func signalIntent() {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(Date().timeIntervalSince1970, forKey: pendingKey)
        defaults?.synchronize()
        NotificationCenter.default.post(name: didReceiveIntent, object: nil)
    }

    /// Call on app foreground — checks if widget set the flag while app was suspended.
    static func consumePendingIntent() -> Bool {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let ts = defaults.object(forKey: pendingKey) as? Double else { return false }

        let age = Date().timeIntervalSince1970 - ts
        defaults.removeObject(forKey: pendingKey)
        defaults.synchronize()

        return age < 90 // only honour intents < 90 seconds old
    }
}
