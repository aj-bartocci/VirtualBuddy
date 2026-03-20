import Foundation
import CryptoKit
import OSLog

/// Pushes OCI artifacts (blobs and manifests) to an OCI-compliant registry.
public final class OCIPushClient: @unchecked Sendable {

    private let logger = Logger(subsystem: "codes.rambo.VirtualBuddy", category: "OCIPushClient")

    private let authHandler: OCIAuthHandler
    private let session: URLSession
    private var isCancelled = false

    /// Chunk size for blob uploads (64 MB).
    public static let defaultChunkSize = 64 * 1024 * 1024

    public init(authHandler: OCIAuthHandler, session: URLSession = .shared) {
        self.authHandler = authHandler
        self.session = session
    }

    /// Push an IPSW file as an OCI artifact with metadata.
    public func push(
        reference: OCIReference,
        ipswURL: URL,
        metadata: VBImageMetadata,
        chunkSize: Int = defaultChunkSize,
        progress: @escaping @Sendable (OCIProgress) -> Void
    ) async throws {
        try checkCancelled()
        logger.info("Pushing \(ipswURL.lastPathComponent) to \(reference.description)")

        // 1. Hash the IPSW
        progress(OCIProgress(phase: .hashing))
        let fileSize = try fileSize(of: ipswURL)
        let ipswDigest = try await StreamingSHA256.digestAsync(of: ipswURL) { bytesProcessed, totalBytes in
            progress(OCIProgress(phase: .hashing, bytesCompleted: bytesProcessed, totalBytes: totalBytes))
        }
        logger.info("IPSW digest: \(ipswDigest)")

        // 2. Create config blob
        let configData = try JSONEncoder().encode(metadata)
        let configDigest = try StreamingSHA256.digestFromData(configData)

        // 3. Check if IPSW blob already exists
        let token = try await authHandler.token(for: reference, action: "push,pull")
        let ipswExists = try await blobExists(reference: reference, digest: ipswDigest, token: token)

        if ipswExists {
            logger.info("IPSW blob already exists, skipping upload")
        } else {
            // 4. Upload IPSW blob
            try await uploadBlob(
                reference: reference,
                fileURL: ipswURL,
                digest: ipswDigest,
                fileSize: fileSize,
                chunkSize: chunkSize,
                progress: progress
            )
        }

        try checkCancelled()

        // 5. Upload config blob
        let configExists = try await blobExists(reference: reference, digest: configDigest, token: token)
        if !configExists {
            try await uploadBlobFromData(reference: reference, data: configData, digest: configDigest)
        }

        // 6. Push manifest
        progress(OCIProgress(phase: .pushingManifest))

        let manifest = OCIManifest(
            config: OCIDescriptor(
                mediaType: OCIMediaType.vbConfig,
                digest: configDigest,
                size: Int64(configData.count)
            ),
            layers: [
                OCIDescriptor(
                    mediaType: OCIMediaType.ipswLayer,
                    digest: ipswDigest,
                    size: fileSize,
                    annotations: [
                        "org.opencontainers.image.title": ipswURL.lastPathComponent,
                        "org.virtualbuddy.build": metadata.build,
                        "org.virtualbuddy.version": metadata.version,
                    ]
                )
            ],
            annotations: [
                "org.opencontainers.image.title": metadata.name,
                "org.virtualbuddy.build": metadata.build,
                "org.virtualbuddy.version": metadata.version,
            ]
        )

        try await pushManifest(reference: reference, manifest: manifest)

        logger.info("Push complete: \(reference.description)")
    }

    /// Cancel any in-progress operation.
    public func cancel() {
        isCancelled = true
    }

    // MARK: - Blob Operations

    /// Check if a blob exists in the registry.
    private func blobExists(reference: OCIReference, digest: String, token: String) async throws -> Bool {
        let url = reference.blobURL(digest: digest)

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return statusCode == 200
    }

    /// Upload a file blob using chunked upload.
    private func uploadBlob(
        reference: OCIReference,
        fileURL: URL,
        digest: String,
        fileSize: Int64,
        chunkSize: Int,
        progress: @escaping @Sendable (OCIProgress) -> Void
    ) async throws {
        let token = try await authHandler.token(for: reference, action: "push,pull")

        // Initiate upload
        let uploadURL = try await initiateUpload(reference: reference, token: token)

        // Upload in chunks
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var bytesUploaded: Int64 = 0
        var currentUploadURL = uploadURL

        while bytesUploaded < fileSize {
            try checkCancelled()

            let remainingBytes = fileSize - bytesUploaded
            let thisChunkSize = min(Int64(chunkSize), remainingBytes)
            guard let chunkData = try fileHandle.read(upToCount: Int(thisChunkSize)), !chunkData.isEmpty else {
                break
            }

            let isLastChunk = (bytesUploaded + Int64(chunkData.count)) >= fileSize

            if isLastChunk {
                // Final chunk: PUT with digest to complete
                try await finalizeUpload(
                    uploadURL: currentUploadURL,
                    data: chunkData,
                    digest: digest,
                    offset: bytesUploaded,
                    totalSize: fileSize,
                    token: token
                )
            } else {
                // Intermediate chunk: PATCH
                currentUploadURL = try await uploadChunk(
                    uploadURL: currentUploadURL,
                    data: chunkData,
                    offset: bytesUploaded,
                    totalSize: fileSize,
                    token: token
                )
            }

            bytesUploaded += Int64(chunkData.count)
            progress(OCIProgress(phase: .uploading, bytesCompleted: bytesUploaded, totalBytes: fileSize))
        }

        logger.info("Blob upload complete: \(digest)")
    }

    /// Upload a small blob from in-memory data (used for config blobs).
    private func uploadBlobFromData(reference: OCIReference, data: Data, digest: String) async throws {
        let token = try await authHandler.token(for: reference, action: "push,pull")
        let uploadURL = try await initiateUpload(reference: reference, token: token)

        // Monolithic upload for small blobs
        try await finalizeUpload(
            uploadURL: uploadURL,
            data: data,
            digest: digest,
            offset: 0,
            totalSize: Int64(data.count),
            token: token
        )
    }

    /// POST to initiate a blob upload, returns the upload URL.
    private func initiateUpload(reference: OCIReference, token: String) async throws -> URL {
        let url = reference.blobUploadURL

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OCIError.uploadFailed("Invalid response when initiating upload")
        }

        guard httpResponse.statusCode == 202 else {
            let body = String(data: data, encoding: .utf8)
            throw OCIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        guard let location = httpResponse.value(forHTTPHeaderField: "Location") else {
            throw OCIError.uploadFailed("No Location header in upload initiation response")
        }

        // Location may be relative or absolute
        if location.hasPrefix("http") {
            return URL(string: location)!
        } else {
            return reference.apiBaseURL.appendingPathComponent(location)
        }
    }

    /// PATCH to upload a chunk of data.
    private func uploadChunk(
        uploadURL: URL,
        data: Data,
        offset: Int64,
        totalSize: Int64,
        token: String
    ) async throws -> URL {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.setValue("\(offset)-\(offset + Int64(data.count) - 1)", forHTTPHeaderField: "Content-Range")
        request.httpBody = data

        let (responseData, response) = try await retryOnAuthFailure(request: request, reference: nil, token: token) {
            try await self.session.data(for: $0)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OCIError.uploadFailed("Invalid response during chunk upload")
        }

        guard httpResponse.statusCode == 202 else {
            let body = String(data: responseData, encoding: .utf8)
            throw OCIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        // Get next upload URL from Location header
        if let location = httpResponse.value(forHTTPHeaderField: "Location") {
            if location.hasPrefix("http") {
                return URL(string: location)!
            } else {
                return URL(string: location, relativeTo: uploadURL)?.absoluteURL ?? uploadURL
            }
        }

        return uploadURL
    }

    /// PUT to finalize the upload with the final chunk and digest.
    private func finalizeUpload(
        uploadURL: URL,
        data: Data,
        digest: String,
        offset: Int64,
        totalSize: Int64,
        token: String
    ) async throws {
        // Append digest query parameter
        var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: true)!
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "digest", value: digest))
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        if totalSize > 0 {
            request.setValue("\(offset)-\(offset + Int64(data.count) - 1)", forHTTPHeaderField: "Content-Range")
        }
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OCIError.uploadFailed("Invalid response when finalizing upload")
        }

        guard httpResponse.statusCode == 201 else {
            let body = String(data: responseData, encoding: .utf8)
            throw OCIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    // MARK: - Manifest

    /// PUT a manifest to the registry.
    private func pushManifest(reference: OCIReference, manifest: OCIManifest) async throws {
        let token = try await authHandler.token(for: reference, action: "push,pull")
        let url = reference.manifestURL

        let data = try JSONEncoder().encode(manifest)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(OCIMediaType.imageManifest, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OCIError.uploadFailed("Invalid response when pushing manifest")
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let body = String(data: responseData, encoding: .utf8)
            throw OCIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        logger.info("Manifest pushed successfully")
    }

    // MARK: - Helpers

    private func fileSize(of url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return Int64(attrs[.size] as? UInt64 ?? 0)
    }

    private func checkCancelled() throws {
        if isCancelled { throw OCIError.cancelled }
    }

    /// Retry a request once if it fails with 401 (token expired).
    private func retryOnAuthFailure(
        request: URLRequest,
        reference: OCIReference?,
        token: String,
        perform: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        let (data, response) = try await perform(request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429 {
            // Rate limited — back off and retry
            let retryAfter = Double(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "5") ?? 5
            logger.warning("Rate limited, retrying after \(retryAfter) seconds")
            try await Task.sleep(for: .seconds(retryAfter))
            return try await perform(request)
        }

        return (data, response)
    }
}

// MARK: - StreamingSHA256 Data Extension

extension StreamingSHA256 {
    /// Compute SHA256 digest of in-memory data.
    static func digestFromData(_ data: Data) throws -> String {
        var hasher = CryptoKit.SHA256()
        hasher.update(data: data)
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }
}
