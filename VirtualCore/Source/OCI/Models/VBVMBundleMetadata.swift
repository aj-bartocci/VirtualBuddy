import Foundation

/// Metadata stored in the OCI config blob for a VM bundle artifact.
/// Describes the bundle structure, layer roles, and host compatibility requirements.
public struct VBVMBundleMetadata: Codable, Sendable {
    public var formatVersion: Int
    public var vmName: String
    public var guestType: String
    public var pushDate: Date
    public var virtualBuddyVersion: String
    public var layers: [LayerInfo]
    public var requirements: Requirements?

    public init(
        formatVersion: Int = 1,
        vmName: String,
        guestType: String,
        pushDate: Date = Date(),
        virtualBuddyVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        layers: [LayerInfo],
        requirements: Requirements? = nil
    ) {
        self.formatVersion = formatVersion
        self.vmName = vmName
        self.guestType = guestType
        self.pushDate = pushDate
        self.virtualBuddyVersion = virtualBuddyVersion
        self.layers = layers
        self.requirements = requirements
    }

    /// Describes a single layer within the VM bundle OCI artifact.
    public struct LayerInfo: Codable, Sendable {
        public var relativePath: String
        public var role: Role
        public var originalSize: Int64?
        public var diskFormat: String?
        public var isCompressed: Bool

        public init(relativePath: String, role: Role, originalSize: Int64? = nil, diskFormat: String? = nil, isCompressed: Bool = false) {
            self.relativePath = relativePath
            self.role = role
            self.originalSize = originalSize
            self.diskFormat = diskFormat
            self.isCompressed = isCompressed
        }

        public enum Role: String, Codable, Sendable {
            case bootDisk
            case extraDisk
            case auxiliaryStorage
            case machineIdentifier
            case hardwareModel
            case config
            case metadata
        }
    }

    /// Host compatibility requirements for the VM bundle.
    public struct Requirements: Codable, Sendable {
        public var minHostVersion: String?
        public var usesASIF: Bool

        public init(minHostVersion: String? = nil, usesASIF: Bool = false) {
            self.minHostVersion = minHostVersion
            self.usesASIF = usesASIF
        }
    }
}

// MARK: - OCI Layer Annotations

public extension VBVMBundleMetadata.LayerInfo {
    /// Standard annotation keys for VM bundle layers.
    enum AnnotationKey {
        public static let bundlePath = "org.virtualbuddy.bundle.path"
        public static let bundleRole = "org.virtualbuddy.bundle.role"
        public static let originalSize = "org.virtualbuddy.original-size"
    }

    /// Build OCI descriptor annotations from this layer info.
    var descriptorAnnotations: [String: String] {
        var annotations: [String: String] = [
            AnnotationKey.bundlePath: relativePath,
            AnnotationKey.bundleRole: role.rawValue,
        ]
        if let originalSize {
            annotations[AnnotationKey.originalSize] = String(originalSize)
        }
        return annotations
    }
}
