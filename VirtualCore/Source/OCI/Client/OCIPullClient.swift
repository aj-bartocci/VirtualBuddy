import Foundation
import OSLog

/// Pulls OCI artifacts (manifests and blobs) from an OCI-compliant registry.
public final class OCIPullClient: @unchecked Sendable {

    private let logger = Logger(subsystem: "codes.rambo.VirtualBuddy", category: "OCIPullClient")

    private let authHandler: OCIAuthHandler
    private let session: URLSession

    /// Active download task, for cancellation support.
    private var activeDownloadTask: URLSessionDownloadTask?
    private var isCancelled = false

    public init(authHandler: OCIAuthHandler, session: URLSession = .shared) {
        self.authHandler = authHandler
        self.session = session
    }

    /// Pull the manifest for a given reference.
    public func pullManifest(reference: OCIReference) async throws -> OCIManifest {
        let token = try await authHandler.token(for: reference, action: "pull")
        let url = reference.manifestURL

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(OCIMediaType.imageManifest, forHTTPHeaderField: "Accept")

        let (data, response) = try await performRequest(request, reference: reference, action: "pull")

        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OCIError.httpError(statusCode: code, body: String(data: data, encoding: .utf8))
        }

        return try JSONDecoder().decode(OCIManifest.self, from: data)
    }

    /// Pull a blob (layer or config) to a destination file.
    public func pullBlob(
        reference: OCIReference,
        descriptor: OCIDescriptor,
        destination: URL,
        progress: @escaping @Sendable (OCIProgress) -> Void
    ) async throws {
        try checkCancelled()

        let token = try await authHandler.token(for: reference, action: "pull")
        let url = reference.blobURL(digest: descriptor.digest)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        progress(OCIProgress(phase: .downloading, bytesCompleted: 0, totalBytes: descriptor.size))

        let (tempURL, response) = try await downloadWithProgress(request: request, descriptor: descriptor, reference: reference, progress: progress)

        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OCIError.httpError(statusCode: code, body: nil)
        }

        // Verify digest
        progress(OCIProgress(phase: .verifying, bytesCompleted: 0, totalBytes: descriptor.size))

        let actualDigest = try StreamingSHA256.digest(of: tempURL)
        guard actualDigest == descriptor.digest else {
            try? FileManager.default.removeItem(at: tempURL)
            throw OCIError.digestMismatch(expected: descriptor.digest, actual: actualDigest)
        }

        // Move to destination
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Full pull: fetch manifest, download the IPSW layer, verify, return local path.
    public func pull(
        reference: OCIReference,
        destinationDirectory: URL,
        progress: @escaping @Sendable (OCIProgress) -> Void
    ) async throws -> URL {
        try checkCancelled()

        logger.info("Pulling \(reference.description)")

        // Fetch manifest
        progress(OCIProgress(phase: .fetchingManifest))
        let manifest = try await pullManifest(reference: reference)

        // Find the IPSW layer
        guard let ipswLayer = manifest.layers.first(where: { $0.mediaType == OCIMediaType.ipswLayer }) else {
            // Fall back to first layer if no specific IPSW media type
            guard let firstLayer = manifest.layers.first else {
                throw OCIError.httpError(statusCode: 0, body: "Manifest contains no layers")
            }
            logger.warning("No layer with IPSW media type found, using first layer")
            return try await pullLayer(firstLayer, reference: reference, destinationDirectory: destinationDirectory, progress: progress)
        }

        return try await pullLayer(ipswLayer, reference: reference, destinationDirectory: destinationDirectory, progress: progress)
    }

    /// Cancel any in-progress download.
    public func cancel() {
        isCancelled = true
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
    }

    // MARK: - Private

    private func pullLayer(
        _ layer: OCIDescriptor,
        reference: OCIReference,
        destinationDirectory: URL,
        progress: @escaping @Sendable (OCIProgress) -> Void
    ) async throws -> URL {
        // Determine filename from annotation or digest
        let filename = layer.annotations?["org.opencontainers.image.title"]
            ?? "\(reference.tag ?? "download").ipsw"

        let destination = destinationDirectory.appendingPathComponent(filename)

        try await pullBlob(reference: reference, descriptor: layer, destination: destination, progress: progress)

        logger.info("Pull complete: \(destination.path)")
        return destination
    }

    /// Perform a data request with automatic token refresh on 401.
    private func performRequest(_ request: URLRequest, reference: OCIReference, action: String) async throws -> (Data, URLResponse) {
        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            // Token may have expired, invalidate and retry once
            authHandler.invalidateToken(for: reference, action: action)
            let newToken = try await authHandler.token(for: reference, action: action)

            var retryRequest = request
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            return try await session.data(for: retryRequest)
        }

        return (data, response)
    }

    /// Download a blob with progress reporting using URLSession delegate.
    private func downloadWithProgress(
        request: URLRequest,
        descriptor: OCIDescriptor,
        reference: OCIReference,
        progress: @escaping @Sendable (OCIProgress) -> Void
    ) async throws -> (URL, URLResponse) {
        try checkCancelled()

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                totalSize: descriptor.size,
                progress: progress,
                completion: { result in
                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            )

            let downloadSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
            let task = downloadSession.downloadTask(with: request)
            activeDownloadTask = task
            task.resume()
        }
    }

    private func checkCancelled() throws {
        if isCancelled { throw OCIError.cancelled }
    }
}

// MARK: - Download Delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let totalSize: Int64
    let progressCallback: @Sendable (OCIProgress) -> Void
    let completion: (Result<(URL, URLResponse), Error>) -> Void
    private var hasCompleted = false

    init(
        totalSize: Int64,
        progress: @escaping @Sendable (OCIProgress) -> Void,
        completion: @escaping (Result<(URL, URLResponse), Error>) -> Void
    ) {
        self.totalSize = totalSize
        self.progressCallback = progress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !hasCompleted else { return }

        // Copy to temp location since the file at `location` is deleted after this method returns
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: location, to: tempURL)
            guard let response = downloadTask.response else {
                hasCompleted = true
                completion(.failure(OCIError.httpError(statusCode: 0, body: "No response")))
                return
            }
            hasCompleted = true
            completion(.success((tempURL, response)))
        } catch {
            hasCompleted = true
            completion(.failure(error))
        }

        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !hasCompleted, let error else { return }
        hasCompleted = true
        completion(.failure(error))
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : totalSize
        progressCallback(OCIProgress(phase: .downloading, bytesCompleted: totalBytesWritten, totalBytes: total))
    }
}
