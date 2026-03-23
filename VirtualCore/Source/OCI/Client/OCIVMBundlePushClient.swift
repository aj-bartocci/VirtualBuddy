import Foundation
import OSLog

/// Pushes a complete `.vbvm` bundle to an OCI registry as a multi-layer artifact.
///
/// Each disk image is compressed with LZFSE and uploaded as its own layer.
/// Small files (config, metadata, identifiers) are uploaded uncompressed.
/// Screenshots, thumbnails, and install data are excluded.
public final class OCIVMBundlePushClient: @unchecked Sendable {

    private let logger = Logger(subsystem: "codes.rambo.VirtualBuddy", category: "OCIVMBundlePushClient")

    private let pushClient: OCIPushClient

    /// Files to exclude from the bundle push.
    private static let excludedFiles: Set<String> = [
        VBVirtualMachine.screenshotFileName,
        VBVirtualMachine.thumbnailFileName,
        VBVirtualMachine._legacyScreenshotFileName,
        VBVirtualMachine._legacyThumbnailFileName,
        VBVirtualMachine.installRestoreFilename,
    ]

    /// File extensions that indicate disk images requiring compression.
    private static let diskImageExtensions: Set<String> = ["img", "dmg", "sparseimage", "asif"]

    public init(pushClient: OCIPushClient) {
        self.pushClient = pushClient
    }

    /// Push a VM bundle to the specified OCI reference.
    public func pushBundle(
        bundleURL: URL,
        reference: OCIReference,
        progress: @escaping @Sendable (OCIProgress) -> Void
    ) async throws {
        try pushClient.checkCancelled()

        logger.info("Pushing VM bundle \(bundleURL.lastPathComponent) to \(reference.description)")

        // Load the VM to get its configuration
        let vm = try VBVirtualMachine(bundleURL: bundleURL, createIfNeeded: false)

        // Enumerate bundle contents
        let entries = try enumerateBundleEntries(bundleURL: bundleURL, vm: vm)

        logger.info("Found \(entries.count) entries to push")

        let token = try await pushClient.authHandler.token(for: reference, action: "push,pull")

        var layerDescriptors: [OCIDescriptor] = []
        var layerInfos: [VBVMBundleMetadata.LayerInfo] = []

        let tempDir = try Self.stagingDirectory(label: "push-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for entry in entries {
            try pushClient.checkCancelled()

            let (descriptor, layerInfo) = try await pushEntry(
                entry,
                bundleURL: bundleURL,
                reference: reference,
                token: token,
                tempDir: tempDir,
                progress: progress
            )

            layerDescriptors.append(descriptor)
            layerInfos.append(layerInfo)
        }

        try pushClient.checkCancelled()

        // Build and upload config blob
        let usesASIF = entries.contains { $0.diskFormat == "asif" }
        let bundleMetadata = VBVMBundleMetadata(
            vmName: vm.name,
            guestType: vm.configuration.systemType.rawValue,
            layers: layerInfos,
            requirements: VBVMBundleMetadata.Requirements(
                minHostVersion: usesASIF ? "26.0" : nil,
                usesASIF: usesASIF
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configData = try encoder.encode(bundleMetadata)
        let configDigest = try StreamingSHA256.digestFromData(configData)

        let configExists = try await pushClient.blobExists(reference: reference, digest: configDigest, token: token)
        if !configExists {
            try await pushClient.uploadBlobFromData(reference: reference, data: configData, digest: configDigest)
        }

        // Push manifest
        progress(OCIProgress(phase: .pushingManifest))

        let manifest = OCIManifest(
            config: OCIDescriptor(
                mediaType: OCIMediaType.vmBundleConfig,
                digest: configDigest,
                size: Int64(configData.count)
            ),
            layers: layerDescriptors,
            annotations: [
                "org.opencontainers.image.title": vm.name,
                "org.virtualbuddy.artifact-type": "vm-bundle",
            ]
        )

        try await pushClient.pushManifest(reference: reference, manifest: manifest)

        logger.info("VM bundle push complete: \(reference.description)")
    }

    // MARK: - Bundle Entry

    /// Represents a file or directory within the bundle to be pushed.
    struct BundleEntry {
        let fileURL: URL
        let relativePath: String
        let role: VBVMBundleMetadata.LayerInfo.Role
        let isDirectory: Bool
        let isDiskImage: Bool
        let diskFormat: String?
    }

    // MARK: - Enumeration

    private func enumerateBundleEntries(bundleURL: URL, vm: VBVirtualMachine) throws -> [BundleEntry] {
        var entries: [BundleEntry] = []
        let fm = FileManager.default

        // Boot disk
        let bootDevice = vm.configuration.hardware.storageDevices.first { $0.isBootVolume }
        if let bootDevice, case .managedImage(let image) = bootDevice.backing {
            let diskURL = vm.diskImageURL(for: image)
            let diskFilename = "\(image.filename).\(image.format.fileExtension)"
            if fm.fileExists(atPath: diskURL.path) {
                entries.append(BundleEntry(
                    fileURL: diskURL,
                    relativePath: diskFilename,
                    role: .bootDisk,
                    isDirectory: false,
                    isDiskImage: true,
                    diskFormat: image.format.fileExtension
                ))
            }
        }

        // Extra disks
        for device in vm.configuration.hardware.storageDevices where !device.isBootVolume && device.isEnabled {
            if case .managedImage(let image) = device.backing {
                let diskURL = vm.diskImageURL(for: image)
                let diskFilename = "\(image.filename).\(image.format.fileExtension)"
                if fm.fileExists(atPath: diskURL.path) {
                    entries.append(BundleEntry(
                        fileURL: diskURL,
                        relativePath: diskFilename,
                        role: .extraDisk,
                        isDirectory: false,
                        isDiskImage: true,
                        diskFormat: image.format.fileExtension
                    ))
                }
            }
        }

        // AuxiliaryStorage
        let auxURL = vm.auxiliaryStorageURL
        if fm.fileExists(atPath: auxURL.path) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: auxURL.path, isDirectory: &isDir)
            entries.append(BundleEntry(
                fileURL: auxURL,
                relativePath: "AuxiliaryStorage",
                role: .auxiliaryStorage,
                isDirectory: isDir.boolValue,
                isDiskImage: false,
                diskFormat: nil
            ))
        }

        // MachineIdentifier
        let machineIdURL = vm.machineIdentifierURL
        if fm.fileExists(atPath: machineIdURL.path) {
            entries.append(BundleEntry(
                fileURL: machineIdURL,
                relativePath: "MachineIdentifier",
                role: .machineIdentifier,
                isDirectory: false,
                isDiskImage: false,
                diskFormat: nil
            ))
        }

        // HardwareModel
        let hwModelURL = vm.hardwareModelURL
        if fm.fileExists(atPath: hwModelURL.path) {
            entries.append(BundleEntry(
                fileURL: hwModelURL,
                relativePath: "HardwareModel",
                role: .hardwareModel,
                isDirectory: false,
                isDiskImage: false,
                diskFormat: nil
            ))
        }

        // .vbdata contents (Config.plist, Metadata.plist) — excluding screenshots/thumbnails/install
        let metaDir = vm.metadataDirectoryURL
        if fm.fileExists(atPath: metaDir.path) {
            let metaContents = try fm.contentsOfDirectory(at: metaDir, includingPropertiesForKeys: nil)
            for fileURL in metaContents {
                let fileName = fileURL.lastPathComponent
                guard !Self.excludedFiles.contains(fileName) else { continue }

                let role: VBVMBundleMetadata.LayerInfo.Role
                if fileName == VBVirtualMachine.configurationFilename {
                    role = .config
                } else if fileName == VBVirtualMachine.metadataFilename {
                    role = .metadata
                } else {
                    continue
                }

                entries.append(BundleEntry(
                    fileURL: fileURL,
                    relativePath: "\(VBVirtualMachine.metadataDirectoryName)/\(fileName)",
                    role: role,
                    isDirectory: false,
                    isDiskImage: false,
                    diskFormat: nil
                ))
            }
        }

        return entries
    }

    // MARK: - Upload

    private func pushEntry(
        _ entry: BundleEntry,
        bundleURL: URL,
        reference: OCIReference,
        token: String,
        tempDir: URL,
        progress: @escaping @Sendable (OCIProgress) -> Void
    ) async throws -> (OCIDescriptor, VBVMBundleMetadata.LayerInfo) {
        if entry.isDirectory {
            return try await pushDirectoryEntry(entry, reference: reference, token: token, tempDir: tempDir, progress: progress)
        } else if entry.isDiskImage {
            return try await pushDiskImageEntry(entry, reference: reference, token: token, tempDir: tempDir, progress: progress)
        } else {
            return try await pushFileEntry(entry, reference: reference, token: token, progress: progress)
        }
    }

    /// Compress and upload a disk image.
    private func pushDiskImageEntry(
        _ entry: BundleEntry,
        reference: OCIReference,
        token: String,
        tempDir: URL,
        progress: @escaping @Sendable (OCIProgress) -> Void
    ) async throws -> (OCIDescriptor, VBVMBundleMetadata.LayerInfo) {
        let originalSize = try pushClient.fileSize(of: entry.fileURL)

        logger.info("Compressing disk image: \(entry.relativePath) (\(originalSize) bytes)")

        // Compress
        let compressedURL = tempDir.appendingPathComponent("\(entry.fileURL.lastPathComponent).lzfse")

        await progress(OCIProgress(phase: .compressing, bytesCompleted: 0, totalBytes: originalSize))

        try await DiskCompressor.compress(inputURL: entry.fileURL, outputURL: compressedURL) { bytesRead, totalBytes in
            progress(OCIProgress(phase: .compressing, bytesCompleted: bytesRead, totalBytes: totalBytes))
        }

        // Hash compressed file
        progress(OCIProgress(phase: .hashing))
        let compressedSize = try pushClient.fileSize(of: compressedURL)
        let digest = try await StreamingSHA256.digestAsync(of: compressedURL) { bytesProcessed, totalBytes in
            progress(OCIProgress(phase: .hashing, bytesCompleted: bytesProcessed, totalBytes: totalBytes))
        }

        // Upload if not already present
        let exists = try await pushClient.blobExists(reference: reference, digest: digest, token: token)
        if !exists {
            try await pushClient.uploadBlob(
                reference: reference,
                fileURL: compressedURL,
                digest: digest,
                fileSize: compressedSize,
                chunkSize: OCIPushClient.defaultChunkSize,
                progress: progress
            )
        } else {
            logger.info("Disk blob already exists, skipping: \(digest)")
        }

        // Clean up compressed file
        try? FileManager.default.removeItem(at: compressedURL)

        let layerInfo = VBVMBundleMetadata.LayerInfo(
            relativePath: entry.relativePath,
            role: entry.role,
            originalSize: originalSize,
            diskFormat: entry.diskFormat,
            isCompressed: true
        )

        let descriptor = OCIDescriptor(
            mediaType: OCIMediaType.vmDiskLayer,
            digest: digest,
            size: compressedSize,
            annotations: layerInfo.descriptorAnnotations
        )

        return (descriptor, layerInfo)
    }

    /// Tar and upload a directory entry (e.g., AuxiliaryStorage).
    private func pushDirectoryEntry(
        _ entry: BundleEntry,
        reference: OCIReference,
        token: String,
        tempDir: URL,
        progress: @escaping @Sendable (OCIProgress) -> Void
    ) async throws -> (OCIDescriptor, VBVMBundleMetadata.LayerInfo) {
        let tarURL = tempDir.appendingPathComponent("\(entry.fileURL.lastPathComponent).tar")

        logger.info("Creating tar for directory: \(entry.relativePath)")

        // Create tar using the tar command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", tarURL.path, "-C", entry.fileURL.deletingLastPathComponent().path, entry.fileURL.lastPathComponent]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw OCIError.uploadFailed("Failed to create tar archive for \(entry.relativePath)")
        }

        // Hash
        progress(OCIProgress(phase: .hashing))
        let tarSize = try pushClient.fileSize(of: tarURL)
        let digest = try await StreamingSHA256.digestAsync(of: tarURL) { bytesProcessed, totalBytes in
            progress(OCIProgress(phase: .hashing, bytesCompleted: bytesProcessed, totalBytes: totalBytes))
        }

        // Upload
        let exists = try await pushClient.blobExists(reference: reference, digest: digest, token: token)
        if !exists {
            try await pushClient.uploadBlob(
                reference: reference,
                fileURL: tarURL,
                digest: digest,
                fileSize: tarSize,
                chunkSize: OCIPushClient.defaultChunkSize,
                progress: progress
            )
        }

        try? FileManager.default.removeItem(at: tarURL)

        let layerInfo = VBVMBundleMetadata.LayerInfo(
            relativePath: entry.relativePath,
            role: entry.role,
            originalSize: tarSize,
            isCompressed: false
        )

        let descriptor = OCIDescriptor(
            mediaType: OCIMediaType.vmFileLayer,
            digest: digest,
            size: tarSize,
            annotations: layerInfo.descriptorAnnotations
        )

        return (descriptor, layerInfo)
    }

    /// Maximum blob size for monolithic (single PUT) upload.
    /// Blobs larger than this use chunked upload to stay within registry limits.
    private static let monolithicUploadLimit = 2 * 1024 * 1024 // 2 MiB

    /// Upload a file directly (config, metadata, identifiers, auxiliary storage).
    private func pushFileEntry(
        _ entry: BundleEntry,
        reference: OCIReference,
        token: String,
        progress: @escaping @Sendable (OCIProgress) -> Void
    ) async throws -> (OCIDescriptor, VBVMBundleMetadata.LayerInfo) {
        let fileSize = try pushClient.fileSize(of: entry.fileURL)

        logger.info("Uploading file: \(entry.relativePath) (\(fileSize) bytes)")

        // For large files, use streaming hash + chunked upload
        if fileSize > Self.monolithicUploadLimit {
            progress(OCIProgress(phase: .hashing))
            let digest = try await StreamingSHA256.digestAsync(of: entry.fileURL) { bytesProcessed, totalBytes in
                progress(OCIProgress(phase: .hashing, bytesCompleted: bytesProcessed, totalBytes: totalBytes))
            }

            let exists = try await pushClient.blobExists(reference: reference, digest: digest, token: token)
            if !exists {
                try await pushClient.uploadBlob(
                    reference: reference,
                    fileURL: entry.fileURL,
                    digest: digest,
                    fileSize: fileSize,
                    progress: progress
                )
            }

            let layerInfo = VBVMBundleMetadata.LayerInfo(
                relativePath: entry.relativePath,
                role: entry.role,
                originalSize: fileSize,
                isCompressed: false
            )

            let descriptor = OCIDescriptor(
                mediaType: OCIMediaType.vmFileLayer,
                digest: digest,
                size: fileSize,
                annotations: layerInfo.descriptorAnnotations
            )

            return (descriptor, layerInfo)
        }

        // Small files: load into memory, monolithic upload
        let data = try Data(contentsOf: entry.fileURL)
        let digest = try StreamingSHA256.digestFromData(data)

        let exists = try await pushClient.blobExists(reference: reference, digest: digest, token: token)
        if !exists {
            try await pushClient.uploadBlobFromData(reference: reference, data: data, digest: digest)
        }

        let layerInfo = VBVMBundleMetadata.LayerInfo(
            relativePath: entry.relativePath,
            role: entry.role,
            originalSize: Int64(data.count),
            isCompressed: false
        )

        let descriptor = OCIDescriptor(
            mediaType: OCIMediaType.vmFileLayer,
            digest: digest,
            size: Int64(data.count),
            annotations: layerInfo.descriptorAnnotations
        )

        return (descriptor, layerInfo)
    }

    // MARK: - Staging Directory

    /// Creates a staging directory under `~/Library/Caches/codes.rambo.VirtualBuddy/OCIStaging/`.
    static func stagingDirectory(label: String) throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let staging = caches
            .appendingPathComponent("codes.rambo.VirtualBuddy", isDirectory: true)
            .appendingPathComponent("OCIStaging", isDirectory: true)
            .appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }
}
