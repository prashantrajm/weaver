import SwiftUI
import AppKit

/// Ensures the app behaves as a regular, foregrounded macOS app even when
/// launched as a SwiftPM executable (which otherwise defaults to a background
/// activation policy and never shows its window).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WeaverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = CaptureController()

    var body: some Scene {
        Window("Weaver", id: "main") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
