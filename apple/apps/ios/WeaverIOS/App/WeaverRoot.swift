#if os(iOS)
import SwiftUI
import WeaverCore
import InspectorKit

/// Root of the iOS app. The Xcode app shell in `apps/ios` renders this from its
/// `@main` `App`; keeping it here lets the whole UI live in the shared SwiftPM
/// library and build with `swift build`.
///
/// Structure is native iOS 26: a `TabView` for the three top-level sections
/// (Traffic · Certificate · Settings), each with its own `NavigationStack`.
/// Liquid Glass is system-provided here — the floating tab bar, toolbars, and
/// search field render on glass automatically; we add custom `glassEffect`
/// surfaces only for app-specific chrome (the capture control, filter chips).
public struct WeaverRootView: View {
    @StateObject private var store = IOSCaptureStore()
    @StateObject private var inspector = InspectorViewModel()

    public init() {}

    public var body: some View {
        TabView {
            Tab("Traffic", systemImage: "arrow.left.arrow.right") {
                TrafficScreen()
            }
            Tab("Certificate", systemImage: "checkmark.seal") {
                CertificateScreen()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsScreen()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .environmentObject(store)
        .environmentObject(inspector)
        .task {
            await store.bootstrap()
            // Verification hook: `SIMCTL_CHILD_WEAVER_SELFTEST=1` (or the
            // env var on device) auto-runs the self-test on launch so real
            // capture can be confirmed without manual taps. No effect otherwise.
            if ProcessInfo.processInfo.environment["WEAVER_SELFTEST"] == "1" {
                store.runSelfTest()
            }
        }
    }
}
#endif
