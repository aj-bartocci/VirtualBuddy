import Foundation

/// Configuration for an OCI registry used to push/pull VM images.
public struct OCIRegistryConfiguration: Codable, Sendable, Hashable {
    /// Registry hostname (e.g., "ghcr.io").
    public var registryURL: String
    /// Repository path (e.g., "myorg/virtualbuddy-images").
    public var repository: String
    /// Whether this registry is enabled for browsing/pulling.
    public var isEnabled: Bool
    /// Authentication method.
    public var authMethod: AuthMethod

    public enum AuthMethod: String, Codable, Sendable, Hashable {
        case anonymous
        case pat
    }

    public init(registryURL: String = "ghcr.io", repository: String = "", isEnabled: Bool = false, authMethod: AuthMethod = .pat) {
        self.registryURL = registryURL
        self.repository = repository
        self.isEnabled = isEnabled
        self.authMethod = authMethod
    }

    /// Construct an `OCIReference` for a given tag.
    public func reference(tag: String) -> OCIReference {
        OCIReference(registry: registryURL, repository: repository, tag: tag)
    }

    /// The base reference (without tag) for listing.
    public var baseReference: OCIReference {
        OCIReference(registry: registryURL, repository: repository)
    }
}

// MARK: - Persistence

public extension OCIRegistryConfiguration {
    private static let userDefaultsKey = "VBOCIRegistryConfiguration"

    /// Load the saved registry configuration, or return a default.
    static var current: OCIRegistryConfiguration {
        get {
            guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
                  let config = try? JSONDecoder().decode(OCIRegistryConfiguration.self, from: data) else {
                return OCIRegistryConfiguration()
            }
            return config
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }
}
