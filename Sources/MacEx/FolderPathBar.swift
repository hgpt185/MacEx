import AppKit
import SwiftUI
import MacExCore

extension Notification.Name { static let macexEditPath = Notification.Name("macexEditPath") }

struct FolderPathBar<Breadcrumbs: View>: View {
    @ObservedObject var browser: BrowserModel
    @ViewBuilder var breadcrumbs: () -> Breadcrumbs
    @State private var editing = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if editing {
                FolderPathEditor(directory: browser.location, error: $error) { url in
                    editing = false; error = nil; browser.navigate(url)
                } cancel: { editing = false; error = nil }
                .frame(height: 28)
            } else {
                HStack { breadcrumbs(); Spacer(minLength: 16) }
                    .contentShape(Rectangle()).onTapGesture { editing = true }
                    .help("Edit path (⌘L)")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("folder-path-error") }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onReceive(NotificationCenter.default.publisher(for: .macexEditPath)) { _ in editing = true }
            .onChange(of: browser.location) { _, _ in editing = false; error = nil }
    }
}

private struct FolderPathEditor: NSViewRepresentable {
    let directory: URL
    @Binding var error: String?
    let commit: (URL) -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: directory.path)
        field.delegate = context.coordinator; field.isEditable = true; field.isSelectable = true
        field.font = .systemFont(ofSize: 13); field.bezelStyle = .roundedBezel
        field.setAccessibilityLabel("Folder path"); field.setAccessibilityIdentifier("folder-path-input")
        DispatchQueue.main.async { [weak field] in
            guard let field, field.window != nil else { return }
            field.window?.makeFirstResponder(field); field.selectText(nil)
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) { context.coordinator.parent = self }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) { coordinator.generation = UUID(); field.delegate = nil }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FolderPathEditor
        var generation = UUID()
        init(_ parent: FolderPathEditor) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) { generation = UUID(); parent.error = nil }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.cancelOperation(_:)) { generation = UUID(); parent.cancel(); return true }
            let complete = command == #selector(NSResponder.insertTab(_:))
            guard complete || command == #selector(NSResponder.insertNewline(_:)), let field = control as? NSTextField else { return false }
            let input = field.stringValue, directory = parent.directory, token = UUID(); generation = token
            Task {
                do {
                    if complete {
                        let result = try await Task.detached(priority: .userInitiated) { try DirectoryPath.complete(input, relativeTo: directory) }.value
                        guard generation == token else { return }
                        field.stringValue = result; textView.string = result; textView.setSelectedRange(NSRange(location: (result as NSString).length, length: 0))
                    } else {
                        let url = try await Task.detached(priority: .userInitiated) { try DirectoryPath.resolve(input, relativeTo: directory) }.value
                        guard generation == token else { return }; parent.commit(url)
                    }
                } catch { if generation == token { parent.error = error.localizedDescription } }
            }
            return true
        }
    }
}
