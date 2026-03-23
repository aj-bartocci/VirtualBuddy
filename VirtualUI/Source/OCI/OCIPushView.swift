import SwiftUI
import VirtualCore
import UniformTypeIdentifiers

/// View for pushing (uploading) a VM image or bundle to an OCI registry.
/// Presented as a sheet from the VM library context menu.
public struct OCIPushView: View {
    @StateObject private var uploadManager = VBUploadManager()
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFileURL: URL?
    @State private var tag: String
    @State private var config = OCIRegistryConfiguration.current
    @State private var showFilePicker = false

    private let defaultDirectory: URL?
    /// When set, the view pushes a VM bundle instead of a single file.
    private let bundleURL: URL?

    public init(defaultDirectory: URL? = nil, suggestedTag: String? = nil, bundleURL: URL? = nil) {
        self.defaultDirectory = defaultDirectory
        self.bundleURL = bundleURL
        _selectedFileURL = State(initialValue: nil)
        _tag = State(initialValue: suggestedTag ?? "")
    }

    private var isBundleMode: Bool { bundleURL != nil }

    private var reference: OCIReference {
        config.reference(tag: tag)
    }

    private var canPush: Bool {
        let hasSource = isBundleMode || selectedFileURL != nil
        return hasSource && !config.registryURL.isEmpty && !config.repository.isEmpty && !tag.isEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    if isBundleMode {
                        bundleSection
                    } else {
                        fileSection
                    }
                    configSection
                    progressSection
                }
                .padding(20)
            }

            Divider()

            bottomBar
        }
        .frame(minWidth: 480, maxWidth: 520, minHeight: 380)
        .onChange(of: showFilePicker) { show in
            guard show else { return }
            showFilePicker = false

            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.data]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.directoryURL = defaultDirectory

            guard panel.runModal() == .OK, let url = panel.url else { return }
            selectedFileURL = url
            if tag.isEmpty {
                tag = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerSection: some View {
        Text(isBundleMode ? "Push VM Bundle to Registry" : "Push to Registry")
            .font(.title2.weight(.semibold))
    }

    @ViewBuilder
    private var bundleSection: some View {
        if let bundleURL {
            VStack(alignment: .leading, spacing: 8) {
                Text("VM Bundle")
                    .font(.callout.weight(.medium))

                HStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.secondary)
                    Text(bundleURL.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                Text("The VM's disk images will be compressed before uploading. Screenshots and thumbnails are excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(isInProgress)
        }
    }

    @ViewBuilder
    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File")
                .font(.callout.weight(.medium))

            HStack {
                if let url = selectedFileURL {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.zipper")
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text("No file selected")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Choose...") {
                    showFilePicker = true
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
        .disabled(isInProgress)
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
        case .compressing(let progress):
            VStack(alignment: .leading, spacing: 8) {
                Text("Compressing disk images...")
                    .font(.callout.weight(.medium))
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .hashing(let progress):
            VStack(alignment: .leading, spacing: 8) {
                Text("Hashing...")
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
        case .compressing, .hashing, .uploading, .pushingManifest:
            return true
        default:
            return false
        }
    }

    private func startPush() {
        if let bundleURL {
            uploadManager.uploadBundle(bundleURL: bundleURL, to: reference)
        } else if let fileURL = selectedFileURL {
            let metadata = VBImageMetadata(
                build: tag,
                version: tag,
                name: fileURL.deletingPathExtension().lastPathComponent
            )
            uploadManager.upload(ipswURL: fileURL, to: reference, metadata: metadata)
        }
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
