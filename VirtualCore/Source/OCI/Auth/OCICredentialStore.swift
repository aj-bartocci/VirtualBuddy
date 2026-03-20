import Foundation
import Security

/// Credential for OCI registry authentication.
public struct OCICredential: Sendable {
    public var username: String
    public var password: String

    /// Create a credential for ghcr.io PAT-based auth.
    /// The username can be any non-empty string for ghcr.io; the password is the PAT.
    public static func pat(_ token: String, username: String = "virtualbuddy") -> OCICredential {
        OCICredential(username: username, password: token)
    }

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Stores OCI registry credentials in the macOS Keychain.
public final class OCICredentialStore: @unchecked Sendable {

    private static let servicePrefix = "codes.rambo.VirtualBuddy.OCI"

    public init() { }

    /// Store a credential for a registry hostname.
    public func store(_ credential: OCICredential, for registry: String) throws {
        // Delete any existing credential first
        try? delete(for: registry)

        let passwordData = Data(credential.password.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.servicePrefix,
            kSecAttrAccount as String: "\(registry):\(credential.username)",
            kSecAttrLabel as String: "VirtualBuddy OCI: \(registry)",
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }

    /// Retrieve the stored credential for a registry hostname.
    public func retrieve(for registry: String) -> OCICredential? {
        // First, try to find matching items by querying all items with our service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.servicePrefix,
            kSecAttrLabel as String: "VirtualBuddy OCI: \(registry)",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let item = result as? [String: Any] else {
            return nil
        }

        guard let account = item[kSecAttrAccount as String] as? String,
              account.hasPrefix("\(registry):"),
              let passwordData = item[kSecValueData as String] as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            return nil
        }

        let username = String(account.dropFirst("\(registry):".count))
        return OCICredential(username: username, password: password)
    }

    /// Delete stored credential for a registry hostname.
    public func delete(for registry: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.servicePrefix,
            kSecAttrLabel as String: "VirtualBuddy OCI: \(registry)",
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Check if credentials exist for a registry without retrieving them.
    public func hasCredential(for registry: String) -> Bool {
        retrieve(for: registry) != nil
    }
}

enum KeychainError: LocalizedError {
    case storeFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .storeFailed(let status):
            return "Failed to store credential in Keychain (status: \(status))"
        case .deleteFailed(let status):
            return "Failed to delete credential from Keychain (status: \(status))"
        }
    }
}
