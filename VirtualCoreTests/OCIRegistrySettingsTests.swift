import XCTest
@testable import VirtualCore

final class OCIRegistrySettingsTests: XCTestCase {

    func testDefaultConfiguration() {
        let config = OCIRegistryConfiguration()
        XCTAssertEqual(config.registryURL, "ghcr.io")
        XCTAssertEqual(config.repository, "")
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.authMethod, .pat)
    }

    func testReferenceGeneration() {
        let config = OCIRegistryConfiguration(
            registryURL: "ghcr.io",
            repository: "myorg/images",
            isEnabled: true
        )

        let ref = config.reference(tag: "macos-15.2")
        XCTAssertEqual(ref.registry, "ghcr.io")
        XCTAssertEqual(ref.repository, "myorg/images")
        XCTAssertEqual(ref.tag, "macos-15.2")
    }

    func testBaseReference() {
        let config = OCIRegistryConfiguration(
            registryURL: "ghcr.io",
            repository: "myorg/images",
            isEnabled: true
        )

        let ref = config.baseReference
        XCTAssertEqual(ref.registry, "ghcr.io")
        XCTAssertEqual(ref.repository, "myorg/images")
    }

    func testCodableRoundtrip() throws {
        let config = OCIRegistryConfiguration(
            registryURL: "registry.example.com",
            repository: "team/vms",
            isEnabled: true,
            authMethod: .anonymous
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OCIRegistryConfiguration.self, from: data)

        XCTAssertEqual(decoded.registryURL, "registry.example.com")
        XCTAssertEqual(decoded.repository, "team/vms")
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.authMethod, .anonymous)
    }
}
