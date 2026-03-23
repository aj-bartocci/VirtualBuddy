import XCTest
@testable import VirtualCore

final class OCIModelsTests: XCTestCase {

    // MARK: - Manifest Encoding/Decoding

    func testManifestRoundtrip() throws {
        let manifest = OCIManifest(
            config: OCIDescriptor(
                mediaType: OCIMediaType.vbConfig,
                digest: "sha256:" + String(repeating: "a", count: 64),
                size: 233
            ),
            layers: [
                OCIDescriptor(
                    mediaType: OCIMediaType.ipswLayer,
                    digest: "sha256:" + String(repeating: "b", count: 64),
                    size: 13_958_643_712,
                    annotations: [
                        "org.opencontainers.image.title": "UniversalMac_15.2_24C101.ipsw"
                    ]
                )
            ],
            annotations: [
                "org.virtualbuddy.build": "24C101",
                "org.virtualbuddy.version": "15.2",
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(manifest)
        let decoded = try JSONDecoder().decode(OCIManifest.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.mediaType, OCIMediaType.imageManifest)
        XCTAssertEqual(decoded.config.mediaType, OCIMediaType.vbConfig)
        XCTAssertEqual(decoded.layers.count, 1)
        XCTAssertEqual(decoded.layers[0].mediaType, OCIMediaType.ipswLayer)
        XCTAssertEqual(decoded.layers[0].size, 13_958_643_712)
        XCTAssertEqual(decoded.layers[0].annotations?["org.opencontainers.image.title"], "UniversalMac_15.2_24C101.ipsw")
        XCTAssertEqual(decoded.annotations?["org.virtualbuddy.build"], "24C101")
    }

    func testManifestDecodingFromJSON() throws {
        let json = """
        {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": {
                "mediaType": "application/vnd.virtualbuddy.config.v1+json",
                "digest": "sha256:44136fa355b311bfa706c3ef27b77e8c4e9b0bc0b6b9b1e0e5b5b1b5b1b5b1b5",
                "size": 100
            },
            "layers": [
                {
                    "mediaType": "application/vnd.virtualbuddy.ipsw.v1",
                    "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    "size": 1000000
                }
            ]
        }
        """

        let manifest = try JSONDecoder().decode(OCIManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.config.size, 100)
        XCTAssertEqual(manifest.layers.count, 1)
    }

    // MARK: - VBImageMetadata

    func testMetadataRoundtrip() throws {
        let metadata = VBImageMetadata(
            build: "24C101",
            version: "15.2",
            name: "macOS 15.2",
            mobileDeviceMinVersion: "1900.4.1",
            requirements: .init(
                minCPUCount: 2,
                minMemorySizeMB: 4096,
                minVersionHost: "13.0.0"
            )
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(VBImageMetadata.self, from: data)

        XCTAssertEqual(decoded.build, "24C101")
        XCTAssertEqual(decoded.version, "15.2")
        XCTAssertEqual(decoded.name, "macOS 15.2")
        XCTAssertEqual(decoded.mobileDeviceMinVersion, "1900.4.1")
        XCTAssertEqual(decoded.requirements?.minCPUCount, 2)
        XCTAssertEqual(decoded.requirements?.minMemorySizeMB, 4096)
    }

    // MARK: - OCIError

    func testErrorResponseDecoding() throws {
        let json = """
        {
            "errors": [
                {
                    "code": "MANIFEST_UNKNOWN",
                    "message": "manifest unknown"
                }
            ]
        }
        """

        let response = try JSONDecoder().decode(OCIErrorResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.errors.count, 1)
        XCTAssertEqual(response.errors[0].code, "MANIFEST_UNKNOWN")
        XCTAssertEqual(response.errors[0].message, "manifest unknown")
    }

    // MARK: - OCIProgress

    func testProgressFractionCompleted() {
        let progress = OCIProgress(phase: .downloading, bytesCompleted: 500, totalBytes: 1000)
        XCTAssertEqual(progress.fractionCompleted, 0.5)
    }

    func testProgressFractionCompletedZeroTotal() {
        let progress = OCIProgress(phase: .downloading, bytesCompleted: 500, totalBytes: 0)
        XCTAssertEqual(progress.fractionCompleted, 0)
    }

    // MARK: - Media Types

    func testMediaTypeConstants() {
        XCTAssertEqual(OCIMediaType.imageManifest, "application/vnd.oci.image.manifest.v1+json")
        XCTAssertEqual(OCIMediaType.ipswLayer, "application/vnd.virtualbuddy.ipsw.v1")
        XCTAssertEqual(OCIMediaType.vbConfig, "application/vnd.virtualbuddy.config.v1+json")
    }

    // MARK: - Descriptor

    func testDescriptorWithAnnotations() throws {
        let descriptor = OCIDescriptor(
            mediaType: OCIMediaType.ipswLayer,
            digest: "sha256:" + String(repeating: "f", count: 64),
            size: 42,
            annotations: ["key": "value"]
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(OCIDescriptor.self, from: data)

        XCTAssertEqual(decoded.annotations?["key"], "value")
        XCTAssertEqual(decoded.size, 42)
    }
}
