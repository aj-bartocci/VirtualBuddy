import SwiftUI
import VirtualCore

/// View for pulling (downloading) a VM bundle from an OCI registry.
public struct OCIPullVMView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var config = OCIRegistryConfiguration.current
    @State private var tag: String = ""
    @State private var pullState: PullState = .idle

    private let libraryURL: URL?
    private var pullTask: Task<Void, Never>?

    public init(libraryURL: URL? = nil) {
        self.libraryURL = libraryURL
    }

    private var reference: OCIReference? {
        guard !config.registryURL.isEmpty, !config.repository.isEmpty, !tag.isEmpty else { return nil }
        return config.reference(tag: tag)
    }

    private var canPull: Bool { reference != nil }

    enum PullState: Equatable {
        case idle
        case pulling(phase: String, progress: Double)
        case complete(path: String)
        case failed(message: String)

        static func == (lhs: PullState, rhs: PullState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.pulling(let a1, let a2), .pulling(let b1, let b2)): return a1 == b1 && a2 == b2
            case (.complete(let a), .complete(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Pull VM Bundle")
                        .font(.title2.weight(.semibold))

                    configSection
                    progressSection
                }
                .padding(20)
            }

            Divider()

            bottomBar
        }
        .frame(minWidth: 480, maxWidth: 520, minHeight: 320)
    }

    // MARK: - Sections

    @ViewBuilder
    private var configSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent {
                TextField("Registry", text: $config.registryURL, prompt: Text("ghcr.io"))
                    .textFieldStyle(.roundedBorder)
            } label: {
                Text("Registry")
                    .frame(width: 80, alignment: .trailing)
            }

            LabeledContent {
                TextField("Repository", text: $config.repository, prompt: Text("org/repo"))
                    .textFieldStyle(.roundedBorder)
            } label: {
                Text("Repository")
                    .frame(width: 80, alignment: .trailing)
            }

            LabeledContent {
                TextField("Tag", text: $tag, prompt: Text("dev-env-xcode16"))
                    .textFieldStyle(.roundedBorder)
            } label: {
                Text("Tag")
                    .frame(width: 80, alignment: .trailing)
            }

            if let reference {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                    Text(reference.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .disabled(isInProgress)
    }

    @ViewBuilder
    private var progressSection: some View {
        switch pullState {
        case .idle:
            EmptyView()
        case .pulling(let phase, let progress):
            VStack(alignment: .leading, spacing: 8) {
                Text(phase)
                    .font(.callout.weight(.medium))
                if progress > 0 {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        case .complete(let path):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Pull complete")
                        .font(.callout.weight(.medium))
                }
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("The VM should appear in your library automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("Pull failed")
                        .font(.callout.weight(.medium))
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }

            Spacer()

            if case .complete = pullState {
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Pull") {
                    startPull()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canPull || isInProgress)
            }
        }
        .controlSize(.large)
        .padding()
    }

    // MARK: - Helpers

    private var isInProgress: Bool {
        if case .pulling = pullState { return true }
        return false
    }

    private func startPull() {
        guard let reference else { return }

        let destinationDir = libraryURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

        pullState = .pulling(phase: "Connecting...", progress: 0)

        Task {
            do {
                let credentialStore = OCICredentialStore()
                let authHandler = OCIAuthHandler(credentialStore: credentialStore)
                let pullClient = OCIPullClient(authHandler: authHandler)
                let bundlePullClient = OCIVMBundlePullClient(pullClient: pullClient, authHandler: authHandler)

                let bundleURL = try await bundlePullClient.pullBundle(
                    reference: reference,
                    destinationDirectory: destinationDir
                ) { progress in
                    Task { @MainActor in
                        let phaseName: String
                        switch progress.phase {
                        case .fetchingManifest: phaseName = "Fetching manifest..."
                        case .downloading: phaseName = "Downloading..."
                        case .decompressing: phaseName = "Decompressing disk images..."
                        case .verifying: phaseName = "Verifying..."
                        case .assembling: phaseName = "Assembling VM bundle..."
                        default: phaseName = "Working..."
                        }
                        self.pullState = .pulling(phase: phaseName, progress: progress.fractionCompleted)
                    }
                }

                await MainActor.run {
                    self.pullState = .complete(path: bundleURL.lastPathComponent)
                }
            } catch {
                await MainActor.run {
                    self.pullState = .failed(message: error.localizedDescription)
                }
            }
        }
    }
}
