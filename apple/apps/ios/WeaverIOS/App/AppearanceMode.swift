#if os(iOS)
import SwiftUI

/// User-chosen appearance, persisted in `UserDefaults` under `appearanceMode`.
/// `.system` follows the device setting; the other two force a scheme. The root
/// reads this via `@AppStorage` and applies `.preferredColorScheme`.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    static let storageKey = "appearanceMode"

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "iphone"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// `nil` lets SwiftUI follow the system; the others pin a scheme.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
#endif
