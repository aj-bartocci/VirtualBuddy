import Foundation
import Combine
import OSLog

/// Download backend that pulls OCI artifacts from a registry.
/// Conforms to `DownloadBackend` so the rest of the app (progress UI, cancellation) works unchanged.
public final class OCIDownloadBackend: NSObject, DownloadBackend {

    private let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "OCIDownloadBackend")

    private let library: VMLibraryController
    private var pullClient: OCIPullClient?
    private var pullTask: Task<Void, Never>?

    public init(library: VMLibraryController, cookie: String?) {
        self.library = library
        super.init()
    }

    public private(set) lazy var statePublisher: AnyPublisher<DownloadState, Never> = $state.eraseToAnyPublisher()

    @Published
    private var state = DownloadState.idle

    // Progress tracking for ETA calculation (mirrors URLSessionDownloadBackend)
    private var elapsedTime: Double = 0
    private var ppsObservations: [Double] = []
    private let ppsObservationsLimit = 500
    private var lastProgressDate = Date()
    private var currentProgress: Double = 0

    @MainActor
    public func startDownload(with url: URL) {
        logger.debug("Start OCI download from \(url.absoluteString)")

        let reference: OCIReference
        do {
            reference = try OCIReference(parsing: url.absoluteString)
        } catch {
            state = .failed("Invalid OCI reference: \(url.absoluteString)")
            return
        }

        state = .preCheck("Authenticating with \(reference.registry)…")

        let credentialStore = OCICredentialStore()
        let authHandler = OCIAuthHandler(credentialStore: credentialStore)
        let client = OCIPullClient(authHandler: authHandler)
        self.pullClient = client

        let destinationDir = VBSettings.current.downloadsDirectoryURL

        // Ensure downloads directory exists
        try? FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        pullTask = Task { [weak self] in
            do {
                let localURL = try await client.pull(
                    reference: reference,
                    destinationDirectory: destinationDir
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.handleProgress(progress)
                    }
                }

                await MainActor.run {
                    self?.state = .done(localURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.state = .failed("Download cancelled.")
                }
            } catch {
                await MainActor.run {
                    self?.logger.error("OCI download failed: \(error, privacy: .public)")
                    self?.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    @MainActor
    public func cancelDownload() {
        pullClient?.cancel()
        pullTask?.cancel()
        pullTask = nil
        pullClient = nil
    }

    // MARK: - Progress

    @MainActor
    private func handleProgress(_ progress: OCIProgress) {
        switch progress.phase {
        case .authenticating:
            state = .preCheck("Authenticating…")
        case .fetchingManifest:
            state = .preCheck("Fetching image manifest…")
        case .hashing:
            state = .preCheck("Verifying integrity…")
        case .downloading:
            updateDownloadProgress(progress)
        case .uploading, .pushingManifest, .compressing, .decompressing, .assembling:
            break // Not applicable for download
        case .verifying:
            state = .preCheck("Verifying download…")
        }
    }

    @MainActor
    private func updateDownloadProgress(_ progress: OCIProgress) {
        let fraction = progress.fractionCompleted
        let interval = Date().timeIntervalSince(lastProgressDate)
        lastProgressDate = Date()

        elapsedTime += interval

        let currentPPS = fraction / elapsedTime
        if currentPPS.isFinite && !currentPPS.isZero && !currentPPS.isNaN {
            ppsObservations.append(currentPPS)
            if ppsObservations.count >= ppsObservationsLimit {
                ppsObservations.removeFirst()
            }
        }

        var eta: Double?
        if currentProgress > 0.01, !ppsObservations.isEmpty {
            let ppsAverage = ppsObservations.reduce(0, +) / Double(ppsObservations.count)
            if ppsAverage > 0 {
                eta = (1 / ppsAverage) - elapsedTime
                if let e = eta, e < 0 { eta = 0 }
            }
        }

        currentProgress = fraction
        state = .downloading(fraction, eta)
    }
}
