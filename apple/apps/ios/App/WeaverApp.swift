import SwiftUI
import WeaverIOS

/// The iOS app shell. All UI lives in the shared `WeaverIOS` SwiftPM
/// library (so it also builds with `swift build`); this `@main` App just hosts
/// its root view. The NEPacketTunnelProvider capture extension is a sibling
/// target added in iOS-P1.
@main
struct WeaverApp: App {
    var body: some Scene {
        WindowGroup {
            WeaverRootView()
        }
    }
}
