import Foundation
import Testing
import MacExCore
@testable import MacEx

@MainActor @Test func librarySettingsCanExplicitlyUseAutomaticLocationForRules() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-rule-default-\(UUID().uuidString)")
    let pictures = root.appendingPathComponent("Pictures")
    try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let browser = BrowserModel(initialLocation: pictures, workspace: AppWorkspace())
    let model = LibraryModel(browser: browser, directory: root.appendingPathComponent("State"), defaultRoots: [pictures])
    defer { model.shutdown(); browser.setVisible(false) }
    for _ in 0..<500 { if model.loaded && !model.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.settings.roots.isEmpty)
    model.addRuleFolder()
    #expect(model.workspace.interaction.request != nil)
    model.workspace.interaction.finish(pictures.path)
    #expect(model.settings.roots.count == 1)
    let selected = try #require(model.settings.roots.first)
    #expect(try FileIdentity(URL(fileURLWithPath: selected)) == FileIdentity(pictures))
    #expect(model.discoveryRoots == [selected])
    #expect(!model.settings.autoInstallers && !model.settings.autoScreenshots)
    for _ in 0..<500 { if !model.scanning { break }; try await Task.sleep(for: .milliseconds(10)) }
}

@MainActor @Test func librarySettingsRulesRequireCustomFoldersAndCanAlwaysBeDisabled() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MacEx-rule-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let browser = BrowserModel(initialLocation: root, workspace: AppWorkspace())
    let model = LibraryModel(browser: browser, directory: root.appendingPathComponent("State"), defaultRoots: [])
    defer { model.shutdown(); browser.setVisible(false) }
    for _ in 0..<500 { if model.loaded { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.loaded)
    let view = LibrarySettingsView(model: model)

    for key in [\LibrarySettings.autoInstallers, \LibrarySettings.autoScreenshots] {
        let binding = view.rule(key, title: "Enable rule?", message: "Custom-folder rule")
        binding.wrappedValue = true
        #expect(!model.settings[keyPath: key])
        #expect(model.workspace.interaction.request == nil)

        model.settings[keyPath: key] = true
        binding.wrappedValue = false
        #expect(!model.settings[keyPath: key])
        #expect(model.workspace.interaction.request == nil)

        model.settings.roots = [root.path]
        binding.wrappedValue = true
        #expect(model.workspace.interaction.request != nil)
        #expect(!model.settings[keyPath: key])
        model.settings.roots = []
        model.workspace.interaction.finish("Enable Rule")
        #expect(!model.settings[keyPath: key])

        model.settings.roots = [root.path]
        binding.wrappedValue = true
        model.workspace.interaction.finish("Enable Rule")
        #expect(model.settings[keyPath: key])
        binding.wrappedValue = false
        model.settings.roots = []
    }
}
