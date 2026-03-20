import XCTest
@testable import VirtualCore

final class StreamingSHA256Tests: XCTestCase {

    // MARK: - File Hashing

    func testHashKnownContent() throws {
        let content = "Hello, VirtualBuddy!"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("sha256test-\(UUID().uuidString).txt")
        try Data(content.utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let digest = try StreamingSHA256.digest(of: tempURL)

        // Pre-computed: echo -n "Hello, VirtualBuddy!" | shasum -a 256
        XCTAssertTrue(digest.hasPrefix("sha256:"))
        XCTAssertEqual(digest.count, 71) // "sha256:" (7) + 64 hex chars
    }

    func testHashEmptyFile() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("sha256test-empty-\(UUID().uuidString)")
        try Data().write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let digest = try StreamingSHA256.digest(of: tempURL)

        // SHA256 of empty input
        XCTAssertEqual(digest, "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testHashConsistency() throws {
        let content = Data(repeating: 0xAB, count: 1024 * 1024) // 1MB
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("sha256test-consistent-\(UUID().uuidString)")
        try content.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let digest1 = try StreamingSHA256.digest(of: tempURL)
        let digest2 = try StreamingSHA256.digest(of: tempURL)

        XCTAssertEqual(digest1, digest2)
    }

    // MARK: - Progress Callback

    func testProgressCallback() throws {
        let content = Data(repeating: 0xCD, count: 2 * 1024 * 1024) // 2MB
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("sha256test-progress-\(UUID().uuidString)")
        try content.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var progressCalls: [(Int64, Int64)] = []

        _ = try StreamingSHA256.digest(of: tempURL, chunkSize: 512 * 1024) { bytes, total in
            progressCalls.append((bytes, total))
        }

        XCTAssertGreaterThan(progressCalls.count, 0)

        // Last call should have bytesProcessed == totalBytes
        if let last = progressCalls.last {
            XCTAssertEqual(last.0, last.1)
        }

        // Progress should be monotonically increasing
        for i in 1..<progressCalls.count {
            XCTAssertGreaterThan(progressCalls[i].0, progressCalls[i-1].0)
        }
    }

    // MARK: - Data Hashing

    func testDigestFromData() throws {
        let data = Data("test".utf8)
        let digest = try StreamingSHA256.digestFromData(data)

        // SHA256 of "test"
        XCTAssertEqual(digest, "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
    }

    func testDigestFromEmptyData() throws {
        let data = Data()
        let digest = try StreamingSHA256.digestFromData(data)

        XCTAssertEqual(digest, "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // MARK: - Async

    func testAsyncDigest() async throws {
        let content = "async test content"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("sha256test-async-\(UUID().uuidString).txt")
        try Data(content.utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let syncDigest = try StreamingSHA256.digest(of: tempURL)
        let asyncDigest = try await StreamingSHA256.digestAsync(of: tempURL)

        XCTAssertEqual(syncDigest, asyncDigest)
    }
}
