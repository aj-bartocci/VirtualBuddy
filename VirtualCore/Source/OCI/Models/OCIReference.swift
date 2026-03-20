import Foundation

/// A parsed OCI image reference (e.g., `ghcr.io/org/repo:tag` or `ghcr.io/org/repo@sha256:...`).
public struct OCIReference: Sendable, Hashable, CustomStringConvertible {
    /// Registry hostname (e.g., "ghcr.io").
    public var registry: String
    /// Repository path (e.g., "org/repo").
    public var repository: String
    /// Tag or digest. Exactly one should be set.
    public var tag: String?
    public var digest: String?

    /// The reference portion (tag or digest) used in API calls.
    public var reference: String {
        if let digest { return digest }
        return tag ?? "latest"
    }

    public var description: String {
        var s = "\(registry)/\(repository)"
        if let digest {
            s += "@\(digest)"
        } else {
            s += ":\(tag ?? "latest")"
        }
        return s
    }

    /// Base URL for OCI Distribution API calls against this reference's registry.
    public var apiBaseURL: URL {
        URL(string: "https://\(registry)")!
    }

    /// URL for manifest operations: `GET/PUT /v2/{repository}/manifests/{reference}`
    public var manifestURL: URL {
        URL(string: "https://\(registry)/v2/\(repository)/manifests/\(reference)")!
    }

    /// URL for blob operations: `GET/HEAD /v2/{repository}/blobs/{digest}`
    public func blobURL(digest: String) -> URL {
        URL(string: "https://\(registry)/v2/\(repository)/blobs/\(digest)")!
    }

    /// URL to initiate a blob upload: `POST /v2/{repository}/blobs/uploads/`
    public var blobUploadURL: URL {
        URL(string: "https://\(registry)/v2/\(repository)/blobs/uploads/")!
    }

    /// URL to list tags: `GET /v2/{repository}/tags/list`
    public var tagsListURL: URL {
        URL(string: "https://\(registry)/v2/\(repository)/tags/list")!
    }

    public init(registry: String, repository: String, tag: String? = nil, digest: String? = nil) {
        self.registry = registry
        self.repository = repository
        self.tag = tag
        self.digest = digest
    }

    /// Parse a string like `ghcr.io/org/repo:tag` or `ghcr.io/org/repo@sha256:abc...`.
    public init(parsing string: String) throws {
        // Try oci:// URL scheme first
        var input = string
        if input.hasPrefix("oci://") {
            input = String(input.dropFirst("oci://".count))
        }

        // Split on @ for digest references
        if let atIndex = input.lastIndex(of: "@") {
            let path = String(input[input.startIndex..<atIndex])
            let digest = String(input[input.index(after: atIndex)...])

            guard digest.hasPrefix("sha256:"), digest.count == 71 else {
                throw OCIError.invalidReference("Invalid digest format in '\(string)'")
            }

            let (registry, repository) = try Self.splitRegistryAndRepository(path)
            self.init(registry: registry, repository: repository, digest: digest)
        }
        // Split on : for tag references (but not port numbers)
        else if let colonIndex = input.lastIndex(of: ":") {
            let path = String(input[input.startIndex..<colonIndex])
            let tag = String(input[input.index(after: colonIndex)...])

            // Ensure the colon isn't part of a port number (e.g., localhost:5000/repo)
            let afterColon = tag
            if afterColon.contains("/") {
                // This is a port number, not a tag
                let (registry, repository) = try Self.splitRegistryAndRepository(input)
                self.init(registry: registry, repository: repository, tag: "latest")
            } else {
                guard Self.isValidTag(tag) else {
                    throw OCIError.invalidReference("Invalid tag '\(tag)' in '\(string)'")
                }
                let (registry, repository) = try Self.splitRegistryAndRepository(path)
                self.init(registry: registry, repository: repository, tag: tag)
            }
        } else {
            let (registry, repository) = try Self.splitRegistryAndRepository(input)
            self.init(registry: registry, repository: repository, tag: "latest")
        }
    }

    /// Convert to a URL with the `oci://` scheme for use in `RestoreImage.url`.
    public var asURL: URL {
        URL(string: "oci://\(description)")!
    }

    // MARK: - Private

    private static func splitRegistryAndRepository(_ path: String) throws -> (String, String) {
        guard let firstSlash = path.firstIndex(of: "/") else {
            throw OCIError.invalidReference("Missing repository in '\(path)'")
        }

        let registry = String(path[path.startIndex..<firstSlash])
        let repository = String(path[path.index(after: firstSlash)...])

        guard !registry.isEmpty else {
            throw OCIError.invalidReference("Empty registry in '\(path)'")
        }
        guard !repository.isEmpty else {
            throw OCIError.invalidReference("Empty repository in '\(path)'")
        }

        return (registry, repository)
    }

    private static func isValidTag(_ tag: String) -> Bool {
        guard !tag.isEmpty, tag.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return tag.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
