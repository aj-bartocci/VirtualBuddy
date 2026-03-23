import XCTest
@testable import VirtualCore

final class OCIReferenceTests: XCTestCase {

    // MARK: - Parsing

    func testParseTagReference() throws {
        let ref = try OCIReference(parsing: "ghcr.io/myorg/images:macos-15.2")
        XCTAssertEqual(ref.registry, "ghcr.io")
        XCTAssertEqual(ref.repository, "myorg/images")
        XCTAssertEqual(ref.tag, "macos-15.2")
        XCTAssertNil(ref.digest)
    }

    func testParseDigestReference() throws {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let ref = try OCIReference(parsing: "ghcr.io/myorg/images@\(digest)")
        XCTAssertEqual(ref.registry, "ghcr.io")
        XCTAssertEqual(ref.repository, "myorg/images")
        XCTAssertNil(ref.tag)
        XCTAssertEqual(ref.digest, digest)
    }

    func testParseDefaultTag() throws {
        let ref = try OCIReference(parsing: "ghcr.io/myorg/images")
        XCTAssertEqual(ref.tag, "latest")
    }

    func testParseOCIScheme() throws {
        let ref = try OCIReference(parsing: "oci://ghcr.io/myorg/images:v1")
        XCTAssertEqual(ref.registry, "ghcr.io")
        XCTAssertEqual(ref.repository, "myorg/images")
        XCTAssertEqual(ref.tag, "v1")
    }

    func testParseNestedRepository() throws {
        let ref = try OCIReference(parsing: "ghcr.io/myorg/sub/repo:tag")
        XCTAssertEqual(ref.registry, "ghcr.io")
        XCTAssertEqual(ref.repository, "myorg/sub/repo")
        XCTAssertEqual(ref.tag, "tag")
    }

    func testParseLocalRegistry() throws {
        let ref = try OCIReference(parsing: "localhost:5000/myrepo:tag")
        XCTAssertEqual(ref.registry, "localhost:5000")
        XCTAssertEqual(ref.repository, "myrepo")
        XCTAssertEqual(ref.tag, "tag")
    }

    // MARK: - Invalid References

    func testInvalidEmptyString() {
        XCTAssertThrowsError(try OCIReference(parsing: ""))
    }

    func testInvalidNoRepository() {
        XCTAssertThrowsError(try OCIReference(parsing: "ghcr.io"))
    }

    func testInvalidDigestFormat() {
        XCTAssertThrowsError(try OCIReference(parsing: "ghcr.io/repo@sha256:tooshort"))
    }

    // MARK: - URL Generation

    func testManifestURL() throws {
        let ref = try OCIReference(parsing: "ghcr.io/org/repo:v1")
        let url = ref.manifestURL
        XCTAssertEqual(url.absoluteString, "https://ghcr.io/v2/org/repo/manifests/v1")
    }

    func testBlobURL() throws {
        let ref = try OCIReference(parsing: "ghcr.io/org/repo:v1")
        let digest = "sha256:" + String(repeating: "b", count: 64)
        let url = ref.blobURL(digest: digest)
        XCTAssertEqual(url.absoluteString, "https://ghcr.io/v2/org/repo/blobs/\(digest)")
    }

    func testTagsListURL() throws {
        let ref = try OCIReference(parsing: "ghcr.io/org/repo:v1")
        let url = ref.tagsListURL
        XCTAssertEqual(url.absoluteString, "https://ghcr.io/v2/org/repo/tags/list")
    }

    func testBlobUploadURL() throws {
        let ref = try OCIReference(parsing: "ghcr.io/org/repo:v1")
        let url = ref.blobUploadURL
        XCTAssertEqual(url.absoluteString, "https://ghcr.io/v2/org/repo/blobs/uploads/")
    }

    // MARK: - OCI URL Roundtrip

    func testAsURLRoundtrip() throws {
        let ref = try OCIReference(parsing: "ghcr.io/org/repo:macos-15.2")
        let url = ref.asURL
        XCTAssertEqual(url.scheme, "oci")

        let roundtripped = try OCIReference(parsing: url.absoluteString)
        XCTAssertEqual(roundtripped.registry, ref.registry)
        XCTAssertEqual(roundtripped.repository, ref.repository)
        XCTAssertEqual(roundtripped.tag, ref.tag)
    }

    // MARK: - Description

    func testDescriptionTag() throws {
        let ref = try OCIReference(parsing: "ghcr.io/org/repo:v1")
        XCTAssertEqual(ref.description, "ghcr.io/org/repo:v1")
    }

    func testDescriptionDigest() throws {
        let digest = "sha256:" + String(repeating: "c", count: 64)
        let ref = try OCIReference(parsing: "ghcr.io/org/repo@\(digest)")
        XCTAssertEqual(ref.description, "ghcr.io/org/repo@\(digest)")
    }
}
