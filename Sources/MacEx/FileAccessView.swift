import SwiftUI
import AppKit

@MainActor private final class FileAccessState: ObservableObject {
    @Published var settingsError = false
    @Published var requesting = false
}

struct FileAccessView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = FileAccessState()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Your files, with your permission", systemImage: "folder.badge.person.crop")
                .font(.system(size: 21, weight: .semibold))
            Text("macOS cannot grant file access while an app is installing. It also will not combine Desktop, Documents, and Downloads into one install prompt. One Full Disk Access switch covers those folders and other protected locations.")
            VStack(alignment: .leading, spacing: 10) {
                Text("One switch for every protected folder").font(.headline)
                Text("Open System Settings, add this copy of MacEx under Privacy & Security → Full Disk Access, and turn it on. Quit and reopen MacEx if macOS asks.")
                Text("This is a broad permission. macOS still enforces other protections. MacEx cannot turn the switch on for you, and you can turn it off later in Settings.")
                    .foregroundStyle(.secondary)
                Text("Open System Settings manually → Privacy & Security → Full Disk Access if needed. MacEx keeps its file workflow in this window.").textSelection(.enabled)
                if state.settingsError { Text("Open System Settings manually, then choose Privacy & Security → Full Disk Access.").foregroundStyle(.orange) }
            }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                Text("Prefer separate prompts? MacEx can ask for Desktop, Documents, and Downloads now, instead of the first time you open each one.")
                    .foregroundStyle(.secondary)
                Button(state.requesting ? "Waiting for macOS…" : "Ask for Desktop, Documents, and Downloads Now") {
                    requestStandardFolders()
                }.disabled(state.requesting)
            }
            HStack {
                Spacer()
                Button("Continue") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            .padding(28).frame(width: 540)
            .onDisappear { UserDefaults.standard.set(true, forKey: "fileAccessChoiceSeen") }
    }

    private func requestStandardFolders() {
        state.requesting = true
        Task.detached {
            let home = FileManager.default.homeDirectoryForCurrentUser
            for name in ["Desktop", "Documents", "Downloads"] {
                let url = home.appendingPathComponent(name, isDirectory: true)
                _ = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
            }
            await MainActor.run { state.requesting = false }
        }
    }
}
