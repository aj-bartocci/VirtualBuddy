import Foundation
import OSLog

/// Pulls a VM bundle OCI artifact and assembles it into a `.vbvm` bundle on disk.
public final class OCIVMBundlePullClient: @unchecked Sendable {

    private let logger = Logger(subsystem: "codes.rambo.VirtualBuddy", category: "OCIVMBundlePullClient")

    private let pullClient: OCIPullClient
    private let authHandler: OCIAuthHandler

    public init(pullClient: OCIPullClient, authHandler: OCIAuthHandler) {
        self.pullClient = pullClient
        self.authHandler = authHandler
    }

    /// Pull a VM bundle from the registry and assemble it into a `.vbvm` directory.
    /// - Parameters:
    ///   - reference: OCI reference to pull.
    ///   - destinationDirectory: Directory where the `.vbvm` bundle will be created.
    ///   - existingManifest: If the manifest was already fetched (e.g., for type detection), pass it here to avoid a redundant fetch.
    ///   - progress: Progress callback.
    /// - Returns: URL of the assembled `.vbvm` bundle.
    public func pullBundle(
        reference: OCIReference,
        destinationDirectory: URL,
        existingManifest: OCIManifest? = nil,
        progress: @escaping @Sendable (OCIProgress) -> Void
    ) async throws -> URL {
        logger.info("Pulling VM bundle from \(reference.description)")

        // Use existing manifest or fetch a new one
        let manifest: OCIManifest
        if let existingManifest {
            manifest = existingManifest
        } else {
            progress(OCIProgress(phase: .fetchingManifest))
            manifest = try await pullClient.pullManifest(reference: reference)
        }

        // Fetch and decode config blob
        let bundleMetadata = try await fetchBundleMetadata(reference: reference, manifest: manifest)

        // Validate compatibility
        try validateCompatibility(bundleMetadata)

        // Create staging directory
        let stagingDir = try OCIVMBundlePushClient.stagingDirectory(label: "pull-\(UUID().uuidString)")

        do {
            // Download and process each layer
            for (index, layer) in manifest.layers.enumerated() {
                let layerInfo = bundleMetadata.layers[safe: index]
                try await downloadAndProcessLayer(
                    layer: layer,
                    layerInfo: layerInfo,
                    reference: reference,
                    stagingDir: stagingDir,
                    progress: progress
                )
            }

            // Assemble the bundle
            progress(OCIProgress(phase: .assembling))
            let bundleURL = try assembleBundle(
                from: stagingDir,
                metadata: bundleMetadata,
                destinationDirectory: destinationDirectory
            )

            // Validate the assembled bundle
            _ = try VBVirtualMachine(bundleURL: bundleURL, createIfNeeded: false)

            logger.info("VM bundle pull complete: \(bundleURL.path)")
            return bundleURL
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            throw error
        }
    }

    // MARK: - Metadata

    private func fetchBundleMetadata(reference: OCIReference, manifest: OCIManifest) async throws -> VBVMBundleMetadata {
        guard manifest.config.mediaType == OCIMediaType.vmBundleConfig else {
            throw OCIError.incompatibleFormat("Not a VM bundle artifact (config type: \(manifest.config.mediaType))")
        }

        let token = try await authHandler.token(for: reference, action: "pull")
        let url = reference.blobURL(digest: manifest.config.digest)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OCIError.httpError(statusCode: code, body: String(data: data, encoding: .utf8))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VBVMBundleMetadata.self, from: data)
    }

    // MARK: - Compatibility

    private func validateCompatibility(_ metadata: VBVMBundleMetadata) throws {
        if let requirements = metadata.requirements {
            if requirements.usesASIF {
                if #unavailable(macOS 26) {
                    throw OCIError.incompatibleFormat("This VM bundle uses ASIF disk format which requires macOS 26 or later.")
                }
            }

            if let minVersion = requirements.minHostVersion {
                let currentVersion = ProcessInfo.processInfo.operatingSystemVersion
                let currentVersionString = "\(currentVersion.majorVersion).\(currentVersion.minorVersion)"
                if currentVersionString.compare(minVersion, options: .numeric) == .orderedAscending {
                    throw OCIError.incompatibleFormat("This VM bundle requires macOS \(minVersion) or later (current: \(currentVersionString)).")
                }
            }
        }
    }

    // MARK: - Download

    private func downloadAndProcessLayer(
        layer: OCIDescriptor,
        layerInfo: VBVMBundleMetadata.LayerInfo?,
        reference: OCIReference,
        stagingDir: URL,
        progress: @escaping @Sendable (OCIProgress) -> Void
    ) async throws {
        let relativePath = layer.annotations?[VBVMBundleMetadata.LayerInfo.AnnotationKey.bundlePath]
            ?? layerInfo?.relativePath
            ?? layer.digest.replacingOccurrences(of: "sha256:", with: "")

        let isCompressed = layer.mediaType == OCIMediaType.vmDiskLayer

        logger.info("Downloading layer: \(relativePath) (compressed: \(isCompressed))")

        // Determine download destination
        let downloadName = isCompressed ? "\(relativePath).lzfse" : relativePath
        let downloadURL = stagingDir.appendingPathComponent(downloadName)

        // Create parent directories
        try FileManager.default.createDirectory(at: downloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Download
        try await pullClient.pullBlob(
            reference: reference,
            descriptor: layer,
            destination: downloadURL,
            progress: progress
        )

        // Post-process
        if isCompressed {
            // Decompress
            let originalSizeStr = layer.annotations?[VBVMBundleMetadata.LayerInfo.AnnotationKey.originalSize]
            let expectedSize = originalSizeStr.flatMap { Int64($0) } ?? layerInfo?.originalSize ?? 0
            let decompressedURL = stagingDir.appendingPathComponent(relativePath)

            try await DiskCompressor.decompress(
                inputURL: downloadURL,
                outputURL: decompressedURL,
                expectedSize: expectedSize
            ) { bytesWritten, expectedSize in
                progress(OCIProgress(phase: .decompressing, bytesCompleted: bytesWritten, totalBytes: expectedSize))
            }

            try FileManager.default.removeItem(at: downloadURL)
        }
    }

    // MARK: - Assembly

    private func assembleBundle(
        from stagingDir: URL,
        metadata: VBVMBundleMetadata,
        destinationDirectory: URL
    ) throws -> URL {
        let bundleName = sanitizeBundleName(metadata.vmName)
        var bundleURL = destinationDirectory.appendingPathComponent("\(bundleName).\(VBVirtualMachine.bundleExtension)")

        // Avoid overwriting existing bundles
        var counter = 1
        while FileManager.default.fileExists(atPath: bundleURL.path) {
            bundleURL = destinationDirectory.appendingPathComponent("\(bundleName) \(counter).\(VBVirtualMachine.bundleExtension)")
            counter += 1
        }

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fm = FileManager.default

        // Move each layer's file to the bundle
        for layerInfo in metadata.layers {
            let sourceURL = stagingDir.appendingPathComponent(layerInfo.relativePath)
            let destURL = bundleURL.appendingPathComponent(layerInfo.relativePath)

            // Create parent directories if needed
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            guard fm.fileExists(atPath: sourceURL.path) else {
                logger.warning("Layer file not found in staging: \(layerInfo.relativePath)")
                continue
            }

            try fm.moveItem(at: sourceURL, to: destURL)
        }

        // Clean up staging
        try? fm.removeItem(at: stagingDir)

        logger.info("Assembled bundle at \(bundleURL.path)")
        return bundleURL
    }

    private func sanitizeBundleName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/:\\")
        let sanitized = name.components(separatedBy: invalidChars).joined(separator: "-")
        return sanitized.isEmpty ? "VM" : sanitized
    }
}

// MARK: - Array Safe Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
