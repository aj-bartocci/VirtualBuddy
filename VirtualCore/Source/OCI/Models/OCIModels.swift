import Foundation

// MARK: - OCI Distribution Spec Models

/// OCI image manifest (application/vnd.oci.image.manifest.v1+json).
public struct OCIManifest: Codable, Sendable {
    public var schemaVersion: Int
    public var mediaType: String
    public var config: OCIDescriptor
    public var layers: [OCIDescriptor]
    public var annotations: [String: String]?

    public init(schemaVersion: Int = 2, mediaType: String = OCIMediaType.imageManifest, config: OCIDescriptor, layers: [OCIDescriptor], annotations: [String: String]? = nil) {
        self.schemaVersion = schemaVersion
        self.mediaType = mediaType
        self.config = config
        self.layers = layers
        self.annotations = annotations
    }
}

/// OCI content descriptor — references a blob by digest and size.
public struct OCIDescriptor: Codable, Sendable {
    public var mediaType: String
    public var digest: String
    public var size: Int64
    public var annotations: [String: String]?

    public init(mediaType: String, digest: String, size: Int64, annotations: [String: String]? = nil) {
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
        self.annotations = annotations
    }
}

/// Token response from the OCI token endpoint.
struct OCITokenResponse: Codable, Sendable {
    var token: String
    var expiresIn: Int?
    var issuedAt: String?

    enum CodingKeys: String, CodingKey {
        case token
        case expiresIn = "expires_in"
        case issuedAt = "issued_at"
    }
}

/// Error response from OCI registry APIs.
public struct OCIErrorResponse: Codable, Sendable {
    public struct ErrorDetail: Codable, Sendable {
        public var code: String
        public var message: String
        public var detail: String?
    }

    public var errors: [ErrorDetail]
}

// MARK: - VirtualBuddy-specific Config

/// Metadata stored in the OCI config blob for a VirtualBuddy image.
public struct VBImageMetadata: Codable, Sendable {
    public var build: String
    public var version: String
    public var name: String
    public var mobileDeviceMinVersion: String?
    public var requirements: Requirements?

    public struct Requirements: Codable, Sendable {
        public var minCPUCount: Int
        public var minMemorySizeMB: Int
        public var minVersionHost: String
    }

    public init(build: String, version: String, name: String, mobileDeviceMinVersion: String? = nil, requirements: Requirements? = nil) {
        self.build = build
        self.version = version
        self.name = name
        self.mobileDeviceMinVersion = mobileDeviceMinVersion
        self.requirements = requirements
    }
}

// MARK: - Media Types

public enum OCIMediaType {
    public static let imageManifest = "application/vnd.oci.image.manifest.v1+json"
    public static let ipswLayer = "application/vnd.virtualbuddy.ipsw.v1"
    public static let vbConfig = "application/vnd.virtualbuddy.config.v1+json"

    // VM bundle types
    public static let vmBundleConfig = "application/vnd.virtualbuddy.vm-config.v1+json"
    public static let vmDiskLayer = "application/vnd.virtualbuddy.vm-disk.v1.lzfse"
    public static let vmFileLayer = "application/vnd.virtualbuddy.vm-file.v1"
}

// MARK: - Progress

/// Progress reporting for OCI operations.
public struct OCIProgress: Sendable {
    public enum Phase: Sendable, Equatable {
        case authenticating
        case fetchingManifest
        case hashing
        case downloading
        case uploading
        case pushingManifest
        case verifying
        case compressing
        case decompressing
        case assembling
    }

    public var phase: Phase
    public var bytesCompleted: Int64
    public var totalBytes: Int64

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesCompleted) / Double(totalBytes)
    }

    public init(phase: Phase, bytesCompleted: Int64 = 0, totalBytes: Int64 = 0) {
        self.phase = phase
        self.bytesCompleted = bytesCompleted
        self.totalBytes = totalBytes
    }
}

// MARK: - Errors

public enum OCIError: LocalizedError {
    case invalidReference(String)
    case authenticationFailed(String)
    case registryError(OCIErrorResponse)
    case httpError(statusCode: Int, body: String?)
    case digestMismatch(expected: String, actual: String)
    case uploadFailed(String)
    case cancelled
    case incompatibleFormat(String)
    case bundleAssemblyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidReference(let ref):
            return "Invalid OCI reference: \(ref)"
        case .authenticationFailed(let msg):
            return "Authentication failed: \(msg)"
        case .registryError(let response):
            let messages = response.errors.map { "\($0.code): \($0.message)" }.joined(separator: ", ")
            return "Registry error: \(messages)"
        case .httpError(let code, let body):
            return "HTTP \(code)\(body.map { ": \($0)" } ?? "")"
        case .digestMismatch(let expected, let actual):
            return "Digest mismatch: expected \(expected), got \(actual)"
        case .uploadFailed(let msg):
            return "Upload failed: \(msg)"
        case .cancelled:
            return "Operation cancelled"
        case .incompatibleFormat(let msg):
            return "Incompatible format: \(msg)"
        case .bundleAssemblyFailed(let msg):
            return "Bundle assembly failed: \(msg)"
        }
    }
}
