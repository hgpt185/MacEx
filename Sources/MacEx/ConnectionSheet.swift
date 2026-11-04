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
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = ConnectionState()

    @State private var moreOptions = false
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            savedList.frame(width: 230)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.connections.contains { $0.id == state.draft.id } ? (state.draft.title.isEmpty ? state.draft.host : state.draft.title) : "New SFTP connection")
                        .font(.system(size: 18, weight: .semibold))
                    Text("The server's identity is verified before you sign in. Nothing connects until you press Connect.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Server", symbol: "server.rack")
                        field("Name (optional)") { TextField("My server", text: $state.draft.title) }
                        HStack(spacing: 10) {
                            field("Host or IP address") { TextField("example.com", text: $state.draft.host).accessibilityIdentifier("sftp-host") }
                            field("Port") { TextField("22", text: $state.port).accessibilityIdentifier("sftp-port") }.frame(width: 90)
                        }
                        HStack(spacing: 10) {
                            field("Username") { TextField("you", text: $state.draft.username).accessibilityIdentifier("sftp-user") }
                            field("Start in folder") { TextField("/home/you", text: $state.draft.path) }
                        }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Sign in", symbol: "key.fill")
                        Picker("", selection: $state.draft.authentication) {
                            Text("Password").tag(SSHAuthentication.password)
                            Text("Private key").tag(SSHAuthentication.key)
                            Text("SSH agent").tag(SSHAuthentication.agent)
                        }.pickerStyle(.segmented).labelsHidden()
                        if state.draft.authentication == .key {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.badge.gearshape").foregroundStyle(.secondary)
                                Text(state.draft.privateKey?.path ?? "No key chosen").font(.system(size: 12)).foregroundStyle(state.draft.privateKey == nil ? .tertiary : .primary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                HeaderButton(title: "Choose Key…", action: chooseKey)
                            }
                        }
                        if state.draft.authentication != .agent {
                            field(state.draft.authentication == .password ? "Password" : "Key passphrase (if any)") {
                                SecureField("", text: $state.secret).accessibilityIdentifier("sftp-secret")
                            }
                            Toggle("Remember in Keychain after signing in", isOn: $state.saveSecret).disabled(!state.saveConnection).font(.system(size: 12))
                        } else {
                            Text("Uses your running SSH agent. Unlock keys there first; agent forwarding is never enabled.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup(isExpanded: $moreOptions) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Save this connection (no passwords are written to disk)", isOn: $state.saveConnection).font(.system(size: 12))
                        HStack(spacing: 4) {
                            if state.draft.authentication != .agent {
                                HeaderButton(title: "Load from Keychain", symbol: "key") {
                                    do { state.secret = try SSHKeychain.load(for: connection()) ?? ""; state.message = state.secret.isEmpty ? "No saved credential for this connection." : "Credential loaded for this connection." }
                                    catch { state.message = error.localizedDescription }
                                }
                                HeaderButton(title: "Forget Keychain Item", symbol: "key.slash") {
                                    do { try SSHKeychain.remove(for: connection()); state.secret = ""; state.message = "Saved credential removed." }
                                    catch { state.message = error.localizedDescription }
                                }
                            }
                            HeaderButton(title: "Host Key", symbol: "checkmark.shield") {
                                do { let connection = try connection(); state.keyReview = try knownHosts.savedFingerprint(connection); state.message = state.keyReview == nil ? "No saved host key for this host and port." : "" }
                                catch { state.message = error.localizedDescription }
                            }
                            HeaderButton(title: "Save Details", symbol: "tray.and.arrow.down") {
                                do { try workspace.saveConnection(connection()); state.message = "Connection details saved. No secret was saved." }
                                catch { state.message = error.localizedDescription }
                            }
                        }
                        if let fingerprint = state.keyReview {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Saved host key for \(state.draft.host):\(state.port)").font(.system(size: 12, weight: .semibold))
                                Text(fingerprint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Text("If the server's key changed, confirm the new one through a trusted channel before forgetting this pin.").font(.system(size: 11)).foregroundStyle(.secondary)
                                HeaderButton(title: "Forget This Host Key", symbol: "trash", role: .destructive) {
                                    do { try knownHosts.forget(connection(), expectedFingerprint: fingerprint); state.keyReview = nil; state.message = "Host-key pin removed. Verify the new fingerprint when you reconnect." }
                                    catch { state.message = error.localizedDescription }
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }.padding(.top, 8)
                } label: { Text("More options").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
                if !state.message.isEmpty {
                    Label(state.message, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                }
                HStack {
                    Text("Transfers create new files; interrupted transfers may leave partial files.").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Cancel") { state.secret = ""; if let onClose { onClose() } else { dismiss() } }.keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).frame(height: 32).background(Capsule().fill(Theme.hover))
                    Button {
                        do {
                            let connection = try connection()
                            if state.saveConnection { try workspace.saveConnection(connection) }
                            let credential = state.secret; state.secret = ""
                            if let onClose { onClose() } else { dismiss() }; workspace.openRemote?(connection, credential, state.saveSecret)
                        } catch { state.message = error.localizedDescription }
                    } label: {
                        Label("Connect", systemImage: "arrow.right.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 32).background(Capsule().fill(Theme.accent))
                    }.buttonStyle(PressableStyle()).keyboardShortcut(.defaultAction).accessibilityLabel("Connect")
                }
            }.frame(maxWidth: 620, alignment: .leading)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { if let initial { load(initial) } }
            .onChange(of: state.draft.authentication) { _, _ in state.secret = ""; state.saveSecret = false }
            .onChange(of: state.draft.host) { _, _ in state.keyReview = nil; state.secret = ""; state.saveSecret = false }
            .onChange(of: state.draft.username) { _, _ in state.secret = ""; state.saveSecret = false }
            .onChange(of: state.draft.privateKey) { _, _ in state.secret = ""; state.saveSecret = false }
            .onChange(of: state.saveConnection) { _, save in if !save { state.saveSecret = false } }
            .onChange(of: state.port) { _, _ in state.keyReview = nil; state.secret = ""; state.saveSecret = false }
            .onDisappear { state.secret = "" }
    }
    private var savedList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).padding(.leading, 6)
            savedRow(symbol: "plus", title: "New connection", subtitle: nil, selected: !workspace.connections.contains { $0.id == state.draft.id }) {
                load(SFTPConnection(host: "", username: NSUserName()))
            }
            ForEach(workspace.connections) { connection in
                savedRow(symbol: "server.rack", title: connection.title.isEmpty ? connection.host : connection.title, subtitle: connection.identity, selected: connection.id == state.draft.id) { load(connection) }
                    .contextMenu {
                        Button("Remove Saved Connection", role: .destructive) {
                            workspace.removeConnection(connection.id)
                            if state.draft.id == connection.id { load(SFTPConnection(host: "", username: NSUserName())) }
                            state.message = "Connection removed. Its host-key pin and Keychain item are managed separately."
                        }
                    }
            }
            if workspace.connections.isEmpty {
                Text("Connections you save appear here.").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.top, 4)
            }
        }
    }
    private func savedRow(symbol: String, title: String, subtitle: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        SavedConnectionRow(symbol: symbol, title: title, subtitle: subtitle, selected: selected, action: action)
    }
    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            content().textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        }
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
        workspace.interaction.choose("Choose an RSA/Ed25519 private key", folder: false) { url in
            if let url { state.draft.privateKey = FolderBookmark(url: url) }
        }
    }
}

private struct SavedConnectionRow: View {
    let symbol: String
    let title: String
    let subtitle: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(selected ? .white : Theme.accent)
                    .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.selection)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if let subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 0)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.selection : hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(PressableStyle()).onHover { hovering = $0 }.animation(Theme.gentle, value: hovering)
    }
}
