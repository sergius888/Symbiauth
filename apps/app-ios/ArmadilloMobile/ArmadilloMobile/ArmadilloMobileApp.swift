// STATUS: ACTIVE
// PURPOSE: app entry point — boots ContentView, checks for pending widget intent on foreground

import SwiftUI
import UIKit

extension Notification.Name {
    /// Posted with `interval: TimeInterval` in userInfo when app moves in/out of background
    static let heartbeatIntervalChanged = Notification.Name("SymbiAuth.heartbeatIntervalChanged")
    static let trustSessionShouldStop = Notification.Name("SymbiAuth.trustSessionShouldStop")
}

@main
struct ArmadilloMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let switchAppearance = UISwitch.appearance()
        switchAppearance.onTintColor = .black
        switchAppearance.thumbTintColor = .white
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Widget intent check
                if AuthorizeCoordinator.consumePendingIntent() {
                    NotificationCenter.default.post(name: AuthorizeCoordinator.didReceiveIntent, object: nil)
                }
                // Restore fast heartbeat in foreground
                NotificationCenter.default.post(name: .heartbeatIntervalChanged, object: nil,
                                                userInfo: ["interval": 10.0])
            case .background:
                // Slow heartbeat to reduce background energy impact
                NotificationCenter.default.post(name: .heartbeatIntervalChanged, object: nil,
                                                userInfo: ["interval": 60.0])
                NotificationCenter.default.post(name: .trustSessionShouldStop, object: nil)
            default:
                break
            }
        }
    }
}
