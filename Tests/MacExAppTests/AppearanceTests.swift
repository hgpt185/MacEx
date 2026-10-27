import AppKit
import SwiftUI
import Testing
@testable import MacEx

@Suite(.serialized) @MainActor struct AppearanceTests {
    @Test func appearanceSelectionUpdatesNativeAndSwiftUIImmediatelyAndPersists() throws {
        let suite = "MacEx-appearance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original; defaults.removePersistentDomain(forName: suite) }
        let model = AppearanceModel(defaults: defaults)
        var observed: [AppAppearance] = []
        let observation = model.$selection.sink { observed.append($0) }
        defer { observation.cancel() }

        model.select(.dark)
        #expect(model.selection == .dark)
        #expect(model.selection.colorScheme == .dark)
        #expect(app.appearance?.name == .darkAqua)
        #expect(defaults.string(forKey: "appearance") == "dark")

        model.select(.light)
        #expect(model.selection == .light)
        #expect(model.selection.colorScheme == .light)
        #expect(app.appearance?.name == .aqua)
        #expect(defaults.string(forKey: "appearance") == "light")
        #expect(observed == [.system, .dark, .light])
        #expect(AppearanceModel(defaults: defaults).selection == .light)
        #expect(app.appearance?.name == .aqua)
    }

    @Test func selectingSystemClearsBothAppearanceOverridesAndSurvivesRelaunch() throws {
        let suite = "MacEx-appearance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original; defaults.removePersistentDomain(forName: suite) }
        defaults.set("dark", forKey: "appearance")
        let model = AppearanceModel(defaults: defaults)
        #expect(model.selection == .dark)
        #expect(app.appearance?.name == .darkAqua)

        model.select(.system)
        #expect(model.selection == .system)
        #expect(model.selection.colorScheme == nil)
        #expect(app.appearance == nil)
        #expect(defaults.string(forKey: "appearance") == "system")
        #expect(AppearanceModel(defaults: defaults).selection == .system)
        #expect(app.appearance == nil)
    }

    @Test func missingOrUnrecognizedPreferenceUsesSystemInsteadOfForcingDark() throws {
        let suite = "MacEx-appearance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original; defaults.removePersistentDomain(forName: suite) }
        app.appearance = NSAppearance(named: .darkAqua)
        #expect(AppearanceModel(defaults: defaults).selection == .system)
        #expect(app.appearance == nil)

        defaults.set("invalid-old-value", forKey: "appearance")
        app.appearance = NSAppearance(named: .darkAqua)
        #expect(AppearanceModel(defaults: defaults).selection == .system)
        #expect(app.appearance == nil)
    }
}
