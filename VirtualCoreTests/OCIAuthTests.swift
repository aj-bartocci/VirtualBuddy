import XCTest
@testable import VirtualCore

final class OCIAuthTests: XCTestCase {

    // MARK: - AuthChallenge Parsing

    func testParseWWWAuthenticateHeader() throws {
        let header = #"Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:org/repo:pull""#
        let challenge = try AuthChallenge(parsing: header)

        XCTAssertEqual(challenge.realm, "https://ghcr.io/token")
        XCTAssertEqual(challenge.service, "ghcr.io")
        XCTAssertEqual(challenge.scope, "repository:org/repo:pull")
    }

    func testParseMinimalHeader() throws {
        let header = #"Bearer realm="https://example.com/token""#
        let challenge = try AuthChallenge(parsing: header)

        XCTAssertEqual(challenge.realm, "https://example.com/token")
        XCTAssertNil(challenge.service)
        XCTAssertNil(challenge.scope)
    }

    func testRejectNonBearerScheme() {
        let header = "Basic realm=\"test\""
        XCTAssertThrowsError(try AuthChallenge(parsing: header))
    }

    // MARK: - Credential Store

    func testCredentialStoreRoundtrip() throws {
        let store = OCICredentialStore()
        let registry = "test-\(UUID().uuidString).example.com"
        let credential = OCICredential.pat("ghp_testtoken12345")

        // Store
        try store.store(credential, for: registry)

        // Retrieve
        let retrieved = store.retrieve(for: registry)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.password, "ghp_testtoken12345")
        XCTAssertEqual(retrieved?.username, "virtualbuddy")

        // Has credential
        XCTAssertTrue(store.hasCredential(for: registry))

        // Clean up
        try store.delete(for: registry)
        XCTAssertFalse(store.hasCredential(for: registry))
    }

    func testCredentialStoreOverwrite() throws {
        let store = OCICredentialStore()
        let registry = "test-overwrite-\(UUID().uuidString).example.com"

        try store.store(.pat("token1"), for: registry)
        try store.store(.pat("token2"), for: registry)

        let retrieved = store.retrieve(for: registry)
        XCTAssertEqual(retrieved?.password, "token2")

        try store.delete(for: registry)
    }

    func testCredentialStoreNoCredential() {
        let store = OCICredentialStore()
        let result = store.retrieve(for: "nonexistent-\(UUID().uuidString).example.com")
        XCTAssertNil(result)
    }

    func testCredentialPATFactory() {
        let cred = OCICredential.pat("mytoken", username: "myuser")
        XCTAssertEqual(cred.username, "myuser")
        XCTAssertEqual(cred.password, "mytoken")
    }

    func testCredentialPATDefaultUsername() {
        let cred = OCICredential.pat("mytoken")
        XCTAssertEqual(cred.username, "virtualbuddy")
    }
}
