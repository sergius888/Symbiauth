// STATUS: ACTIVE
// PURPOSE: widget AppIntent — FaceID via authenticationPolicy, signals main app to send intent.ok

import AppIntents
import WidgetKit

struct AuthorizeIntent: AppIntent {
    static var title: LocalizedStringResource = "Authorize Mac"
    static var description = IntentDescription("Unlock your Mac vault with Face ID")

    // Enforces biometric auth before perform() runs
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult {
        // Write flag to App Group UserDefaults — main app picks it up on next foreground
        let defaults = UserDefaults(suiteName: "group.com.dreiglaser")
        defaults?.set(Date().timeIntervalSince1970, forKey: "intent.pending.ts")
        defaults?.synchronize()
        return .result()
    }
}
