import Foundation
import Combine
import OSLog

/// Manages uploading (pushing) VM images to an OCI registry.
public final class VBUploadManager: ObservableObject {

    private let logger = Logger(subsystem: "codes.rambo.VirtualBuddy", category: "VBUploadManager")

    @Published public private(set) var uploadState: UploadState = .idle

    private var pushClient: OCIPushClient?
    private var uploadTask: Task<Void, Never>?

    public init() { }

    public enum UploadState: Equatable {
        case idle
        case compressing(progress: Double)
        case hashing(progress: Double)
        case uploading(progress: Double, eta: Double?)
        case pushingManifest
        case complete(reference: String)
        case failed(message: String)

        public static func == (lhs: UploadState, rhs: UploadState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.compressing(let a), .compressing(let b)): return a == b
            case (.hashing(let a), .hashing(let b)): return a == b
            case (.uploading(let a1, let a2), .uploading(let b1, let b2)): return a1 == b1 && a2 == b2
            case (.pushingManifest, .pushingManifest): return true
            case (.complete(let a), .complete(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    /// Push an IPSW file to the specified OCI reference.
    @MainActor
    public func upload(ipswURL: URL, to reference: OCIReference, metadata: VBImageMetadata) {
        logger.info("Starting upload of \(ipswURL.lastPathComponent) to \(reference.description)")

        uploadState = .hashing(progress: 0)

        let credentialStore = OCICredentialStore()
        let authHandler = OCIAuthHandler(credentialStore: credentialStore)
        let client = OCIPushClient(authHandler: authHandler)
        self.pushClient = client

        // ETA tracking for upload phase
        var uploadStartTime: Date?
        var uploadElapsed: Double = 0

        uploadTask = Task { [weak self] in
            do {
                try await client.push(
                    reference: reference,
                    ipswURL: ipswURL,
                    metadata: metadata
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch progress.phase {
                        case .hashing:
                            self.uploadState = .hashing(progress: progress.fractionCompleted)
                        case .uploading:
                            if uploadStartTime == nil {
                                uploadStartTime = Date()
                            }
                            uploadElapsed = Date().timeIntervalSince(uploadStartTime ?? Date())
                            let fraction = progress.fractionCompleted
                            var eta: Double?
                            if fraction > 0.01, uploadElapsed > 0 {
                                eta = (uploadElapsed / fraction) - uploadElapsed
                                if let e = eta, e < 0 { eta = 0 }
                            }
                            self.uploadState = .uploading(progress: fraction, eta: eta)
                        case .pushingManifest:
                            self.uploadState = .pushingManifest
                        default:
                            break
                        }
                    }
                }

                await MainActor.run {
                    self?.uploadState = .complete(reference: reference.description)
                    self?.logger.info("Upload complete: \(reference.description)")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.uploadState = .failed(message: "Upload cancelled.")
                }
            } catch {
                await MainActor.run {
                    self?.logger.error("Upload failed: \(error, privacy: .public)")
                    self?.uploadState = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    /// Push a VM bundle to the specified OCI reference.
    @MainActor
    public func uploadBundle(bundleURL: URL, to reference: OCIReference) {
        logger.info("Starting bundle upload of \(bundleURL.lastPathComponent) to \(reference.description)")

        uploadState = .compressing(progress: 0)

        let credentialStore = OCICredentialStore()
        let authHandler = OCIAuthHandler(credentialStore: credentialStore)
        let client = OCIPushClient(authHandler: authHandler)
        self.pushClient = client

        let bundlePushClient = OCIVMBundlePushClient(pushClient: client)

        var uploadStartTime: Date?
        var uploadElapsed: Double = 0

        uploadTask = Task { [weak self] in
            do {
                try await bundlePushClient.pushBundle(
                    bundleURL: bundleURL,
                    reference: reference
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch progress.phase {
                        case .compressing:
                            self.uploadState = .compressing(progress: progress.fractionCompleted)
                        case .hashing:
                            self.uploadState = .hashing(progress: progress.fractionCompleted)
                        case .uploading:
                            if uploadStartTime == nil {
                                uploadStartTime = Date()
                            }
                            uploadElapsed = Date().timeIntervalSince(uploadStartTime ?? Date())
                            let fraction = progress.fractionCompleted
                            var eta: Double?
                            if fraction > 0.01, uploadElapsed > 0 {
                                eta = (uploadElapsed / fraction) - uploadElapsed
                                if let e = eta, e < 0 { eta = 0 }
                            }
                            self.uploadState = .uploading(progress: fraction, eta: eta)
                        case .pushingManifest:
                            self.uploadState = .pushingManifest
                        default:
                            break
                        }
                    }
                }

                await MainActor.run {
                    self?.uploadState = .complete(reference: reference.description)
                    self?.logger.info("Bundle upload complete: \(reference.description)")
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.uploadState = .failed(message: "Upload cancelled.")
                }
            } catch {
                await MainActor.run {
                    self?.logger.error("Bundle upload failed: \(error, privacy: .public)")
                    self?.uploadState = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    /// Cancel an in-progress upload.
    @MainActor
    public func cancel() {
        pushClient?.cancel()
        uploadTask?.cancel()
        uploadTask = nil
        pushClient = nil
    }
}
