import SwiftUI
import VirtualCore

/// View for pushing (uploading) a VM image to an OCI registry.
/// Presented as a sheet from the VM library context menu.
public struct OCIPushView: View {
    @StateObject private var uploadManager = VBUploadManager()
    @Environment(\.dismiss) private var dismiss

    private let ipswURL: URL
    @State private var tag: String
    @State private var config = OCIRegistryConfiguration.current

    public init(ipswURL: URL, suggestedTag: String? = nil) {
        self.ipswURL = ipswURL
        _tag = State(initialValue: suggestedTag ?? ipswURL.deletingPathExtension().lastPathComponent)
    }

    private var reference: OCIReference {
        config.reference(tag: tag)
    }

    private var canPush: Bool {
        !config.registryURL.isEmpty && !config.repository.isEmpty && !tag.isEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    configSection
                    progressSection
                }
                .padding(20)
            }

            Divider()

            bottomBar
        }
        .frame(minWidth: 480, maxWidth: 520, minHeight: 340)
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Push to Registry")
                .font(.title2.weight(.semibold))

            HStack(spacing: 6) {
                Image(systemName: "doc.zipper")
                    .foregroundStyle(.secondary)
                Text(ipswURL.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

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
                TextField("Tag", text: $tag, prompt: Text("macos-15.2-24C101"))
                    .textFieldStyle(.roundedBorder)
            } label: {
                Text("Tag")
                    .frame(width: 80, alignment: .trailing)
            }

            if canPush {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle")
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
        switch uploadManager.uploadState {
        case .idle:
            EmptyView()
        case .hashing(let progress):
            VStack(alignment: .leading, spacing: 8) {
                Text("Hashing file...")
                    .font(.callout.weight(.medium))
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .uploading(let progress, let eta):
            VStack(alignment: .leading, spacing: 8) {
                Text("Uploading...")
                    .font(.callout.weight(.medium))
                ProgressView(value: progress)
                HStack {
                    Text("\(Int(progress * 100))%")
                    Spacer()
                    if let eta {
                        Text("ETA: \(formattedETA(eta))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .pushingManifest:
            VStack(alignment: .leading, spacing: 8) {
                Text("Pushing manifest...")
                    .font(.callout.weight(.medium))
                ProgressView()
                    .controlSize(.small)
            }
        case .complete(let ref):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Push complete")
                        .font(.callout.weight(.medium))
                }
                Text(ref)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("Push failed")
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
                if isInProgress {
                    uploadManager.cancel()
                }
                dismiss()
            }

            Spacer()

            if isInProgress {
                Button("Stop") {
                    uploadManager.cancel()
                }
            } else if case .complete = uploadManager.uploadState {
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Push") {
                    startPush()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canPush)
            }
        }
        .controlSize(.large)
        .padding()
    }

    // MARK: - Helpers

    private var isInProgress: Bool {
        switch uploadManager.uploadState {
        case .hashing, .uploading, .pushingManifest:
            return true
        default:
            return false
        }
    }

    private func startPush() {
        let metadata = VBImageMetadata(
            build: tag,
            version: tag,
            name: ipswURL.deletingPathExtension().lastPathComponent
        )
        uploadManager.upload(ipswURL: ipswURL, to: reference, metadata: metadata)
    }

    private func formattedETA(_ eta: Double) -> String {
        let time = Int(eta)
        let seconds = time % 60
        let minutes = (time / 60) % 60
        let hours = time / 3600

        if hours >= 1 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
