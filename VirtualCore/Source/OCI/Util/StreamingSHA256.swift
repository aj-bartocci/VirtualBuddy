import Foundation
import CryptoKit

/// Computes SHA256 digest of a file by streaming chunks, without loading the entire file into memory.
public enum StreamingSHA256 {

    /// Default chunk size for reading (1 MB).
    public static let defaultChunkSize = 1024 * 1024

    /// Compute the SHA256 digest of a file.
    /// - Parameters:
    ///   - url: File URL to hash.
    ///   - chunkSize: Size of each read chunk in bytes.
    ///   - progress: Optional callback reporting `(bytesProcessed, totalBytes)`.
    /// - Returns: Hex-encoded digest string prefixed with `sha256:`.
    public static func digest(
        of url: URL,
        chunkSize: Int = defaultChunkSize,
        progress: ((_ bytesProcessed: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        let fileSize = try Int64(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0)

        var hasher = SHA256()
        var bytesProcessed: Int64 = 0

        while true {
            guard let chunk = try fileHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
            bytesProcessed += Int64(chunk.count)
            progress?(bytesProcessed, fileSize)
        }

        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    /// Async version of `digest(of:chunkSize:progress:)` that yields to avoid blocking.
    public static func digestAsync(
        of url: URL,
        chunkSize: Int = defaultChunkSize,
        progress: ((_ bytesProcessed: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) async throws -> String {
        try await Task.detached {
            try digest(of: url, chunkSize: chunkSize, progress: progress)
        }.value
    }
}
