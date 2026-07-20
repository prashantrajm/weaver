#if os(iOS)
import SwiftUI
import WeaverCore
import InspectorKit

/// Root of the iOS app. The Xcode app shell in `apps/ios` renders this from its
/// `@main` `App`; keeping it here lets the whole UI live in the shared SwiftPM
/// library and build with `swift build`.
///
/// Two flavors gated by `WEAVER_VPN` (see project.yml): the App Store build
/// captures via an in-app proxy (Traffic · Settings — certificates live inside
/// Settings); the VPN build adds automatic packet-tunnel capture
/// (Traffic · Setup · Settings).
/// Liquid Glass is system-provided — the floating tab bar, toolbars, and search
/// field render on glass automatically; we add custom `glassEffect` surfaces only
/// for app-specific chrome (the capture control, filter chips).
public struct WeaverRootView: View {
    @StateObject private var store = IOSCaptureStore()
    @StateObject private var inspector = InspectorViewModel()
    @StateObject private var captures = TunnelCaptureReader()
    #if WEAVER_VPN
    @StateObject private var tunnel = TunnelController()
    #endif
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system

    public init() {}

    public var body: some View {
        TabView {
            Tab("Traffic", systemImage: "arrow.left.arrow.right") {
                TrafficScreen()
            }
            #if WEAVER_VPN
            Tab("Setup", systemImage: "checkmark.seal") {
                SetupGuideScreen()
            }
            #endif
            Tab("Settings", systemImage: "gearshape") {
                SettingsScreen()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .preferredColorScheme(appearance.colorScheme)
        .environmentObject(store)
        .environmentObject(inspector)
        .environmentObject(captures)
        #if WEAVER_VPN
        .environmentObject(tunnel)
        #endif
        .task {
            await store.bootstrap()
            #if WEAVER_VPN
            await tunnel.refresh()
            #endif
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
