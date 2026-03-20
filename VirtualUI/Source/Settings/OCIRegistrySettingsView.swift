import SwiftUI
import VirtualCore

struct OCIRegistrySettingsView: View {
    @State private var config = OCIRegistryConfiguration.current
    @State private var patInput = ""
    @State private var connectionStatus: ConnectionStatus = .idle
    @State private var showPAT = false

    private let credentialStore = OCICredentialStore()

    private enum ConnectionStatus: Equatable {
        case idle
        case testing
        case success
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable OCI Registry", isOn: $config.isEnabled)
            } header: {
                Text("Registry")
            } footer: {
                Text("Pull and push VM images from an OCI-compliant container registry like GitHub Container Registry (ghcr.io).")
                    .settingsFooterStyle()
            }

            if config.isEnabled {
                Section {
                    TextField("Registry", text: $config.registryURL, prompt: Text("ghcr.io"))

                    TextField("Repository", text: $config.repository, prompt: Text("org/virtualbuddy-images"))
                } header: {
                    Text("Connection")
                } footer: {
                    Text("The repository path where VM images are stored.")
                        .settingsFooterStyle()
                }

                Section {
                    Picker("Authentication", selection: $config.authMethod) {
                        Text("Personal Access Token").tag(OCIRegistryConfiguration.AuthMethod.pat)
                        Text("Anonymous").tag(OCIRegistryConfiguration.AuthMethod.anonymous)
                    }

                    if config.authMethod == .pat {
                        HStack {
                            if showPAT {
                                TextField("Personal Access Token", text: $patInput, prompt: Text("ghp_..."))
                            } else {
                                SecureField("Personal Access Token", text: $patInput, prompt: Text("ghp_..."))
                            }
                            Button {
                                showPAT.toggle()
                            } label: {
                                Image(systemName: showPAT ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                        }

                        if credentialStore.hasCredential(for: config.registryURL) && patInput.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Token stored in Keychain")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    SettingsFooter {
                        Text("Credentials are stored securely in the macOS Keychain.")
                    } helpText: {
                        Text("For ghcr.io, create a Personal Access Token with **read:packages** scope for pulling, and **write:packages** for pushing. The username can be any non-empty value.")
                    }
                }

                Section {
                    HStack {
                        Button("Test Connection") {
                            testConnection()
                        }
                        .disabled(connectionStatus == .testing || config.registryURL.isEmpty || config.repository.isEmpty)

                        Spacer()

                        connectionStatusView
                    }
                }
            }
        }
        .navigationTitle(Text("Registry"))
        .onChange(of: config) { newValue in
            OCIRegistryConfiguration.current = newValue
        }
        .onChange(of: patInput) { newValue in
            guard !newValue.isEmpty else { return }
            try? credentialStore.store(.pat(newValue), for: config.registryURL)
        }
        .task {
            if credentialStore.hasCredential(for: config.registryURL) {
                // Don't load actual PAT into the text field for security
                patInput = ""
            }
        }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch connectionStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
                .controlSize(.small)
        case .success:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected")
            }
            .font(.caption)
        case .failed(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func testConnection() {
        connectionStatus = .testing

        Task {
            do {
                let reference = config.baseReference
                let authHandler = OCIAuthHandler(credentialStore: credentialStore)
                _ = try await authHandler.token(for: reference, action: "pull")

                await MainActor.run {
                    connectionStatus = .success
                }
            } catch {
                await MainActor.run {
                    connectionStatus = .failed(error.localizedDescription)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Registry Settings") {
    SettingsScreen.preview(.registry)
}
#endif
