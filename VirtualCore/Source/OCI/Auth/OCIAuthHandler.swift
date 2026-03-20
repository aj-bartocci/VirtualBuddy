import Foundation
import OSLog

/// Handles OCI registry authentication (Docker v2 token flow).
///
/// Flow:
/// 1. Client hits registry → gets 401 with `WWW-Authenticate` header
/// 2. Parse realm, service, scope from the header
/// 3. Exchange credentials (or anonymous) for a Bearer token at the realm URL
/// 4. Cache token per scope, auto-refresh on expiry
public final class OCIAuthHandler: @unchecked Sendable {

    private let logger = Logger(subsystem: "codes.rambo.VirtualBuddy", category: "OCIAuthHandler")

    private let credentialStore: OCICredentialStore
    private let session: URLSession

    /// Cached tokens keyed by scope string.
    private var tokenCache: [String: CachedToken] = [:]
    private let lock = NSLock()

    private struct CachedToken {
        let token: String
        let expiresAt: Date
    }

    public init(credentialStore: OCICredentialStore, session: URLSession = .shared) {
        self.credentialStore = credentialStore
        self.session = session
    }

    /// Get a valid Bearer token for the given reference and scope action (e.g., "pull" or "push,pull").
    public func token(for reference: OCIReference, action: String) async throws -> String {
        let scope = "repository:\(reference.repository):\(action)"

        // Check cache
        if let cached = getCachedToken(for: scope), cached.expiresAt > Date().addingTimeInterval(30) {
            return cached.token
        }

        // Discover auth challenge
        let challenge = try await discoverChallenge(for: reference)

        // Exchange for token
        let tokenResponse = try await exchangeToken(challenge: challenge, scope: scope, registry: reference.registry)

        // Cache it
        let expiresIn = tokenResponse.expiresIn ?? 300
        let cachedToken = CachedToken(token: tokenResponse.token, expiresAt: Date().addingTimeInterval(Double(expiresIn)))
        setCachedToken(cachedToken, for: scope)

        return tokenResponse.token
    }

    /// Invalidate cached token for the given scope, forcing re-authentication on next call.
    public func invalidateToken(for reference: OCIReference, action: String) {
        let scope = "repository:\(reference.repository):\(action)"
        lock.lock()
        tokenCache.removeValue(forKey: scope)
        lock.unlock()
    }

    // MARK: - Private

    private func getCachedToken(for scope: String) -> CachedToken? {
        lock.lock()
        defer { lock.unlock() }
        return tokenCache[scope]
    }

    private func setCachedToken(_ token: CachedToken, for scope: String) {
        lock.lock()
        tokenCache[scope] = token
        lock.unlock()
    }

    /// Hit the registry's /v2/ endpoint to get the WWW-Authenticate challenge.
    private func discoverChallenge(for reference: OCIReference) async throws -> AuthChallenge {
        let url = URL(string: "https://\(reference.registry)/v2/")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OCIError.authenticationFailed("Invalid response from registry")
        }

        // 200 means no auth required (unlikely for ghcr.io but possible for local registries)
        if httpResponse.statusCode == 200 {
            return AuthChallenge(realm: nil, service: nil, scope: nil)
        }

        guard httpResponse.statusCode == 401 else {
            throw OCIError.httpError(statusCode: httpResponse.statusCode, body: nil)
        }

        guard let header = httpResponse.value(forHTTPHeaderField: "WWW-Authenticate") ?? httpResponse.value(forHTTPHeaderField: "Www-Authenticate") else {
            throw OCIError.authenticationFailed("No WWW-Authenticate header in 401 response")
        }

        return try AuthChallenge(parsing: header)
    }

    /// Exchange credentials for a Bearer token at the token endpoint.
    private func exchangeToken(challenge: AuthChallenge, scope: String, registry: String) async throws -> OCITokenResponse {
        // No auth required
        guard let realm = challenge.realm else {
            return OCITokenResponse(token: "", expiresIn: 3600)
        }

        var components = URLComponents(string: realm)!

        var queryItems = components.queryItems ?? []
        if let service = challenge.service {
            queryItems.append(URLQueryItem(name: "service", value: service))
        }
        queryItems.append(URLQueryItem(name: "scope", value: scope))
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"

        // Add Basic auth if we have credentials
        if let credential = credentialStore.retrieve(for: registry) {
            let basicAuth = Data("\(credential.username):\(credential.password)".utf8).base64EncodedString()
            request.setValue("Basic \(basicAuth)", forHTTPHeaderField: "Authorization")
            logger.debug("Using stored credentials for \(registry)")
        } else {
            logger.debug("No credentials found for \(registry), attempting anonymous auth")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OCIError.authenticationFailed("Invalid token response")
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let body = String(data: data, encoding: .utf8)
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw OCIError.authenticationFailed("Invalid credentials for \(registry). Ensure your PAT has the required scopes (read:packages for pull, write:packages for push).")
            }
            throw OCIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        return try JSONDecoder().decode(OCITokenResponse.self, from: data)
    }
}

// MARK: - Auth Challenge Parsing

struct AuthChallenge {
    var realm: String?
    var service: String?
    var scope: String?

    /// Parse a `WWW-Authenticate: Bearer realm="...",service="...",scope="..."` header.
    init(parsing header: String) throws {
        guard header.hasPrefix("Bearer ") else {
            throw OCIError.authenticationFailed("Unsupported auth scheme: \(header)")
        }

        let params = String(header.dropFirst("Bearer ".count))
        var parsed: [String: String] = [:]

        // Simple key="value" parser
        let scanner = Scanner(string: params)
        scanner.charactersToBeSkipped = nil

        while !scanner.isAtEnd {
            // Skip whitespace and commas
            _ = scanner.scanCharacters(from: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))

            guard let key = scanner.scanUpToString("=") else { break }
            guard scanner.scanString("=") != nil else { break }

            let value: String
            if scanner.scanString("\"") != nil {
                value = scanner.scanUpToString("\"") ?? ""
                _ = scanner.scanString("\"")
            } else {
                value = scanner.scanUpToString(",") ?? ""
            }

            parsed[key] = value
        }

        self.realm = parsed["realm"]
        self.service = parsed["service"]
        self.scope = parsed["scope"]
    }

    init(realm: String?, service: String?, scope: String?) {
        self.realm = realm
        self.service = service
        self.scope = scope
    }
}
