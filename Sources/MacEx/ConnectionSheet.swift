import SwiftUI
import MacExCore

@MainActor private final class ConnectionState: ObservableObject {
    @Published var draft = SFTPConnection(host: "", username: NSUserName())
    @Published var port = "22"
    @Published var secret = ""
    @Published var saveConnection = true
    @Published var saveSecret = false
    @Published var message = ""
    @Published var keyReview: String?
}

struct ConnectionSheet: View {
    @ObservedObject var workspace: AppWorkspace
    let knownHosts: SSHKnownHosts
    var initial: SFTPConnection?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = ConnectionState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect with SFTP").font(.title2)
            Text("The server host key is verified before authentication. No connection starts until you press Connect.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Menu("Saved Connections") {
                    ForEach(workspace.connections) { connection in
                        Button(connection.title.isEmpty ? connection.identity : connection.title) { load(connection) }
                    }
                }.disabled(workspace.connections.isEmpty)
                Button("New") { load(SFTPConnection(host: "", username: NSUserName())) }
                Spacer()
                Button("Remove Saved Connection") { workspace.removeConnection(state.draft.id); state.message = "Connection removed. Its host-key pin and Keychain item are managed separately." }
                    .disabled(!workspace.connections.contains { $0.id == state.draft.id })
            }
            TextField("Connection name", text: $state.draft.title).textFieldStyle(.roundedBorder)
            HStack {
                TextField("Hostname / IP address", text: $state.draft.host).accessibilityIdentifier("sftp-host")
                TextField("Port", text: $state.port).frame(width: 75).accessibilityIdentifier("sftp-port")
            }.textFieldStyle(.roundedBorder)
            TextField("Username", text: $state.draft.username).textFieldStyle(.roundedBorder).accessibilityIdentifier("sftp-user")
            TextField("Initial remote path", text: $state.draft.path).textFieldStyle(.roundedBorder)
            Picker("Authentication", selection: $state.draft.authentication) {
                ForEach(SSHAuthentication.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if state.draft.authentication == .key {
                HStack {
                    Text(state.draft.privateKey?.path ?? "Choose an RSA/Ed25519 private key").lineLimit(2).font(.caption).textSelection(.enabled)
                    Spacer(); Button("Choose Key…", action: chooseKey)
                }
            }
            if state.draft.authentication != .agent {
                SecureField(state.draft.authentication == .password ? "Password" : "Key passphrase (if encrypted)", text: $state.secret)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("sftp-secret")
                HStack {
                    Button("Load from Keychain") {
                        do { state.secret = try SSHKeychain.load(for: connection()) ?? ""; state.message = state.secret.isEmpty ? "No saved credential for this connection." : "Credential loaded for this connection." }
                        catch { state.message = error.localizedDescription }
                    }
                    Button("Remove from Keychain") {
                        do { try SSHKeychain.remove(for: connection()); state.secret = ""; state.message = "Saved credential removed." }
                        catch { state.message = error.localizedDescription }
                    }
                }
                Toggle("Save password/passphrase in Keychain after successful authentication", isOn: $state.saveSecret).disabled(!state.saveConnection)
            } else { Text("Uses the existing SSH_AUTH_SOCK agent. Load/unlock keys in your agent first. Agent forwarding is never enabled.").font(.caption).foregroundStyle(.secondary) }
            Toggle("Save connection details (host, username, port, path, key bookmark)", isOn: $state.saveConnection)
            Text("Passwords and passphrases are never stored in workspace files. Downloads/uploads create new files; partial transfers may remain if interrupted.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Review Saved Host Key") {
                    do { let connection = try connection(); state.keyReview = try knownHosts.savedFingerprint(connection); state.message = state.keyReview == nil ? "No saved host key for this host and port." : "" }
                    catch { state.message = error.localizedDescription }
                }
                Spacer()
                Button("Save Details") {
                    do { try workspace.saveConnection(connection()); state.message = "Connection details saved. No secret was saved." }
                    catch { state.message = error.localizedDescription }
                }
            }
            if let fingerprint = state.keyReview {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved host key: \(state.draft.host):\(state.port)").font(.headline)
                    Text(fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("If a server key changed, verify its replacement through a separate trusted source before removing this pin. The next connection will require fingerprint confirmation again.").font(.caption)
                    Button("Forget This Saved Host Key", role: .destructive) {
                        do { try knownHosts.forget(connection(), expectedFingerprint: fingerprint); state.keyReview = nil; state.message = "Host-key pin removed after review. Reconnect and verify the new fingerprint." }
                        catch { state.message = error.localizedDescription }
                    }
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if !state.message.isEmpty { Text(state.message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Cancel") { state.secret = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect") {
                    do {
                        let connection = try connection()
                        if state.saveConnection { try workspace.saveConnection(connection) }
                        let credential = state.secret; state.secret = ""
                        dismiss(); workspace.openRemote?(connection, credential, state.saveSecret)
                    } catch { state.message = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 580)
            .onAppear { if let initial { load(initial) } }
            .onChange(of: state.draft.authentication) { _, _ in state.secret = ""; state.saveSecret = false }
            .onChange(of: state.draft.host) { _, _ in state.keyReview = nil; state.secret = ""; state.saveSecret = false }
            .onChange(of: state.draft.username) { _, _ in state.secret = ""; state.saveSecret = false }
            .onChange(of: state.draft.privateKey) { _, _ in state.secret = ""; state.saveSecret = false }
            .onChange(of: state.saveConnection) { _, save in if !save { state.saveSecret = false } }
            .onChange(of: state.port) { _, _ in state.keyReview = nil; state.secret = ""; state.saveSecret = false }
            .onDisappear { state.secret = "" }
    }
    private func load(_ connection: SFTPConnection) {
        state.draft = connection; state.port = String(connection.port); state.secret = ""; state.saveSecret = false; state.keyReview = nil; state.message = ""
    }
    private func connection() throws -> SFTPConnection {
        var result = state.draft
        guard let enteredPort = Int(state.port) else { throw FileFailure.message("Enter a port from 1 to 65535.") }
        result.port = enteredPort
        if result.authentication == .key, result.privateKey == nil { throw FileFailure.message("Choose a private key.") }
        return try result.validated()
    }
    private func chooseKey() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.resolvesAliases = false; panel.allowsMultipleSelection = false; panel.prompt = "Choose Private Key"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            state.draft.privateKey = FolderBookmark(url: url)
        }
    }
}
