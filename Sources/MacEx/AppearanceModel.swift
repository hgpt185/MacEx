import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Shared by the topbar and Settings; System leaves both UI frameworks following macOS.
@MainActor final class AppearanceModel: ObservableObject {
    static let shared = AppearanceModel()
    @Published private(set) var selection: AppAppearance
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: "appearance").flatMap(AppAppearance.init(rawValue:)) ?? .system
        NSApplication.shared.appearance = selection.nativeAppearance
    }

    func select(_ value: AppAppearance) {
        selection = value
        defaults.set(value.rawValue, forKey: "appearance")
        NSApplication.shared.appearance = value.nativeAppearance
    }
}
