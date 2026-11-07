import SwiftUI
import AppKit
import PDFKit

/// Quick Look stays in the current window; its independent URL does not move the file selection.
struct LibraryPreviewOverlay: View {
    @ObservedObject var model: LibraryModel
    @State private var size = CGSize(width: 840, height: 580)
    @State private var initialSize: CGSize?
    @State private var fillsWindow = false
    var body: some View {
        GeometryReader { geometry in
            let width = fillsWindow ? geometry.size.width : min(size.width, max(0, geometry.size.width - 32))
            let height = fillsWindow ? geometry.size.height : min(size.height, max(0, geometry.size.height - 32))
            ZStack {
                Color.black.opacity(0.28).contentShape(Rectangle()).onTapGesture { model.closePreview() }
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Button { model.closePreview() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close preview").help("Close preview (Esc)")
                        Text(model.previewURL?.lastPathComponent ?? "Preview").font(.headline).lineLimit(1)
                        Spacer()
                        Button { model.stepPreview(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous preview").disabled(!model.canStepPreview(-1))
                        Button { model.stepPreview(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next preview").disabled(!model.canStepPreview(1))
                        Button { fillsWindow.toggle() } label: { Image(systemName: fillsWindow ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.accessibilityLabel(fillsWindow ? "Reduce preview" : "Fill window with preview")
                    }.buttonStyle(.plain).padding(16)
                    Divider()
                    if let url = model.previewURL { StandaloneInlinePreview(url: url).frame(maxWidth: .infinity, maxHeight: .infinity).id(url) }
                    HStack {
                        Text("← → Previous / Next · Space or Esc to close").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !fillsWindow {
                            Image(systemName: "line.3.horizontal.decrease").rotationEffect(.degrees(-45)).padding(8)
                                .contentShape(Rectangle()).help("Drag to resize preview")
                                .gesture(DragGesture().onChanged { value in
                                    if initialSize == nil { initialSize = size }
                                    let origin = initialSize ?? size
                                    size = CGSize(width: max(420, min(geometry.size.width - 32, origin.width + value.translation.width * 2)), height: max(300, min(geometry.size.height - 32, origin.height + value.translation.height * 2)))
                                }.onEnded { _ in initialSize = nil })
                        }
                    }.padding(.leading, 16).frame(height: 34)
                }.frame(width: width, height: height).background(Theme.surface, in: RoundedRectangle(cornerRadius: fillsWindow ? 0 : 14))
                    .overlay(RoundedRectangle(cornerRadius: fillsWindow ? 0 : 14).stroke(Theme.hairline))
                    .shadow(color: .black.opacity(0.22), radius: 22).accessibilityIdentifier("quick-look-overlay")
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ShortcutHelpOverlay: View {
    let close: () -> Void
    private var shortcuts: [MenuShortcut] { NSApp.mainMenu.map { MenuShortcut.read($0) } ?? [] }
    var body: some View {
        ZStack {
            Color.black.opacity(0.28).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Keyboard Shortcuts").font(.title2.bold()); Spacer(); Button("Done", action: close).keyboardShortcut(.cancelAction) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(Set(shortcuts.map(\.section))).sorted(), id: \.self) { section in
                            Text(section).font(.headline).padding(.top, 8)
                            ForEach(shortcuts.filter { $0.section == section }) { shortcut in
                                HStack { Text(shortcut.title); Spacer(); Text(shortcut.keys).foregroundStyle(.secondary).monospaced() }
                            }
                        }
                        Text("File views").font(.headline).padding(.top, 8)
                        HStack { Text("Rename selected file"); Spacer(); Text("Return") }
                        HStack { Text("Toggle Quick Look"); Spacer(); Text("Space") }
                        HStack { Text("Previous / Next preview"); Spacer(); Text("← →") }
                        HStack { Text("Cancel editing / Close overlay"); Spacer(); Text("Esc") }
                    }.font(.callout).padding(.trailing, 8)
                }
            }.padding(24).frame(maxWidth: 540, maxHeight: 620).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16)).padding(24)
                .accessibilityIdentifier("shortcut-help-overlay")
        }
    }
}

struct LibraryOnboardingOverlay: View {
    @ObservedObject var model: LibraryModel
    @State private var step = 0
    var body: some View {
        ZStack {
            Color.black.opacity(0.28).contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("Welcome to MacEx").font(.title.bold()); Spacer(); Text("\(step + 1) of 3").foregroundStyle(.secondary) }
                if step == 0 {
                    Label("Choose your folders", systemImage: "folder.badge.plus").font(.title2)
                    Text("Your standard folders are ready in the library. Add another folder or review folder access in Settings. Online-only contents are skipped.")
                    Text("\(model.discoveryRoots.count) folders available").font(.callout).foregroundStyle(.secondary)
                    Button("Add Folder…", action: model.addFolder)
                } else if step == 1 {
                    Label("Open or take a quick look", systemImage: "eye").font(.title2)
                    Text("Double-click a file to open it in its default app. Select a file and press Space to preview it here. Use the arrow keys to browse previews, and Esc to close.")
                } else {
                    Label("Find space to free up", systemImage: "sparkles").font(.title2)
                    Text("Free Up Space groups old downloads, large files and extra copies. Review your choices before moving anything to Trash. Use ⌘Z to undo.")
                }
                HStack {
                    Button("Skip") { model.finishOnboarding() }
                    Spacer()
                    if step > 0 { Button("Back") { step -= 1 } }
                    Button(step == 2 ? "Done" : "Continue") { if step == 2 { model.finishOnboarding() } else { step += 1 } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(maxWidth: 540).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16)).padding(24)
                .accessibilityIdentifier("onboarding-overlay")
        }
    }
}

extension LibraryModel {
    func finishOnboarding() { settings.onboardingComplete = true; onboardingPresented = false; save() }

    /// nil lets the ordinary file-view key handling run; false passes only to native controls.
    func handleOverlayKey(_ event: NSEvent) -> Bool? {
        guard previewURL != nil || shortcutsPresented || onboardingPresented else { return nil }
        let command = event.modifierFlags.contains(.command)
        if command && [4, 12].contains(event.keyCode) { return false } // Hide and Quit stay available.
        if shortcutsPresented {
            if event.keyCode == 53 || command && event.keyCode == 44 { shortcutsPresented = false }
            return true
        }
        if onboardingPresented { return command ? true : false }
        if event.keyCode == 53 || !command && event.keyCode == 49 { closePreview(); return true }
        if !command && [123, 124, 125, 126].contains(event.keyCode) {
            stepPreview([123, 126].contains(event.keyCode) ? -1 : 1); return true
        }
        // Native Copy/Select All may target preview text; menu close/help actions remain available.
        if command && [8, 0].contains(event.keyCode) {
            if let text = browser.window?.firstResponder as? NSTextView, !text.isEditable { return false }
            var view = browser.window?.firstResponder as? NSView
            while let current = view {
                if current is PDFView { return false }
                view = current.superview
            }
            return true
        }
        if command && [13, 16, 44].contains(event.keyCode) { return false }
        return true
    }
}
