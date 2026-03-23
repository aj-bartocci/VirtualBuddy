import Foundation
import OSLog

/// Fetches available images from an OCI registry and converts them into `RestoreImage` entries
/// that can be merged into a `SoftwareCatalog`.
public final class OCICatalogProvider: @unchecked Sendable {

    private let logger = Logger(subsystem: "codes.rambo.VirtualBuddy", category: "OCICatalogProvider")

    private let authHandler: OCIAuthHandler
    private let session: URLSession

    public init(authHandler: OCIAuthHandler, session: URLSession = .shared) {
        self.authHandler = authHandler
        self.session = session
    }

    /// Convenience initializer using the shared credential store.
    public convenience init() {
        let credentialStore = OCICredentialStore()
        let authHandler = OCIAuthHandler(credentialStore: credentialStore)
        self.init(authHandler: authHandler)
    }

    /// Fetch available images from the configured OCI registry.
    /// Returns `RestoreImage` entries with `ociReference` set, suitable for merging into a catalog.
    public func fetchImages(config: OCIRegistryConfiguration) async throws -> [RestoreImage] {
        guard config.isEnabled, !config.registryURL.isEmpty, !config.repository.isEmpty else {
            return []
        }

        let reference = config.baseReference

        // Fetch tags
        let tags = try await fetchTags(reference: reference)

        logger.info("Found \(tags.count) tags in \(reference.registry)/\(reference.repository)")

        // Fetch manifest for each tag to get metadata
        var images: [RestoreImage] = []

        for tag in tags {
            do {
                let tagRef = OCIReference(registry: reference.registry, repository: reference.repository, tag: tag)
                let image = try await fetchImageMetadata(reference: tagRef)
                // VM bundles are pulled via the dedicated Pull VM flow, not the installer
                guard !image.isVMBundle else {
                    logger.info("Skipping VM bundle tag \(tag) from restore image catalog")
                    continue
                }
                images.append(image)
            } catch {
                logger.warning("Failed to fetch metadata for tag \(tag): \(error, privacy: .public)")
            }
        }

        return images
    }

    // MARK: - Private

    private func fetchTags(reference: OCIReference) async throws -> [String] {
        let token = try await authHandler.token(for: reference, action: "pull")

        var request = URLRequest(url: reference.tagsListURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OCIError.httpError(statusCode: code, body: String(data: data, encoding: .utf8))
        }

        struct TagsList: Decodable {
            var tags: [String]?
        }

        let tagsList = try JSONDecoder().decode(TagsList.self, from: data)
        return tagsList.tags ?? []
    }

    private func fetchImageMetadata(reference: OCIReference) async throws -> RestoreImage {
        let token = try await authHandler.token(for: reference, action: "pull")

        var request = URLRequest(url: reference.manifestURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(OCIMediaType.imageManifest, forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OCIError.httpError(statusCode: code, body: String(data: data, encoding: .utf8))
        }

        let manifest = try JSONDecoder().decode(OCIManifest.self, from: data)

        // Detect artifact type from config media type
        let isVMBundle = manifest.config.mediaType == OCIMediaType.vmBundleConfig
        let artifactType = isVMBundle ? "vm-bundle" : "ipsw"

        // Try to fetch config blob for richer metadata
        var metadata: VBImageMetadata?
        var bundleMetadata: VBVMBundleMetadata?
        if isVMBundle {
            bundleMetadata = try? await fetchVMBundleConfigBlob(reference: reference, descriptor: manifest.config)
        } else if manifest.config.mediaType == OCIMediaType.vbConfig {
            metadata = try? await fetchConfigBlob(reference: reference, descriptor: manifest.config)
        }

        // Build RestoreImage from manifest annotations + config metadata
        let tag = reference.tag ?? "unknown"
        let build = metadata?.build
            ?? manifest.annotations?["org.virtualbuddy.build"]
            ?? tag
        let version = metadata?.version
            ?? manifest.annotations?["org.virtualbuddy.version"]
            ?? tag
        let name: String
        if let bundleMetadata {
            name = bundleMetadata.vmName
        } else {
            name = metadata?.name
                ?? manifest.annotations?["org.opencontainers.image.title"]
                ?? "OCI: \(tag)"
        }

        let layerSize = manifest.layers.reduce(Int64(0)) { $0 + $1.size }

        return RestoreImage(
            id: "oci-\(reference.registry)-\(reference.repository)-\(tag)",
            group: CatalogGroup.ociGroup.id,
            channel: isVMBundle ? CatalogChannel.ociVMBundleChannel.id : CatalogChannel.ociChannel.id,
            requirements: RequirementSet.ociDefault.id,
            name: name,
            build: build,
            version: SoftwareVersion(string: version) ?? SoftwareVersion(major: 0, minor: 0, patch: 0),
            mobileDeviceMinVersion: SoftwareVersion(string: metadata?.mobileDeviceMinVersion ?? "") ?? SoftwareVersion(major: 0, minor: 0, patch: 0),
            url: reference.asURL,
            downloadSize: UInt64(layerSize),
            ociReference: reference.description,
            ociArtifactType: artifactType
        )
    }

    private func fetchConfigBlob(reference: OCIReference, descriptor: OCIDescriptor) async throws -> VBImageMetadata {
        let token = try await authHandler.token(for: reference, action: "pull")
        let url = reference.blobURL(digest: descriptor.digest)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)

        return try JSONDecoder().decode(VBImageMetadata.self, from: data)
    }

    private func fetchVMBundleConfigBlob(reference: OCIReference, descriptor: OCIDescriptor) async throws -> VBVMBundleMetadata {
        let token = try await authHandler.token(for: reference, action: "pull")
        let url = reference.blobURL(digest: descriptor.digest)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VBVMBundleMetadata.self, from: data)
    }
}

// MARK: - OCI Catalog Defaults

public extension CatalogGroup {
    /// Default group for OCI registry images.
    static let ociGroup = CatalogGroup(
        id: "oci-registry",
        name: "OCI Registry",
        majorVersion: SoftwareVersion(major: 0, minor: 0, patch: 0),
        image: .placeholder,
        darkImage: nil
    )
}

public extension CatalogChannel {
    /// Default channel for OCI registry images.
    static let ociChannel = CatalogChannel(
        id: "oci",
        name: "Registry",
        note: "Images from OCI registry",
        icon: "shippingbox"
    )

    /// Channel for OCI VM bundle artifacts.
    static let ociVMBundleChannel = CatalogChannel(
        id: "oci-vm-bundle",
        name: "VM Bundles",
        note: "Pre-configured VM bundles from OCI registry",
        icon: "shippingbox.fill"
    )
}

public extension RequirementSet {
    /// Permissive default requirement set for OCI images (requirements unknown).
    static let ociDefault = RequirementSet(
        id: "oci-default",
        minCPUCount: 2,
        minMemorySizeMB: 4096,
        minVersionHost: SoftwareVersion(major: 13, minor: 0, patch: 0)
    )
}
