import Foundation
import Compression
import OSLog

/// Streaming LZFSE compression/decompression for disk images using Apple's Compression framework.
/// LZFSE is Apple's native algorithm, available on all supported macOS versions, and handles
/// zero-filled regions in raw disk images extremely well.
public enum DiskCompressor {

    private static let logger = Logger(subsystem: "codes.rambo.VirtualBuddy", category: "DiskCompressor")

    /// Buffer size for streaming I/O (1 MB).
    private static let bufferSize = 1024 * 1024

    /// Compress a file using LZFSE streaming compression.
    /// - Parameters:
    ///   - inputURL: Source file to compress.
    ///   - outputURL: Destination for compressed output.
    ///   - progress: Callback with `(bytesRead, totalInputSize)`.
    public static func compress(
        inputURL: URL,
        outputURL: URL,
        progress: @escaping @Sendable (_ bytesRead: Int64, _ totalBytes: Int64) -> Void
    ) async throws {
        try await Task.detached {
            try performCompression(inputURL: inputURL, outputURL: outputURL, progress: progress)
        }.value
    }

    /// Decompress an LZFSE-compressed file.
    /// - Parameters:
    ///   - inputURL: Compressed source file.
    ///   - outputURL: Destination for decompressed output.
    ///   - expectedSize: Expected decompressed size (for progress reporting).
    ///   - progress: Callback with `(bytesWritten, expectedSize)`.
    public static func decompress(
        inputURL: URL,
        outputURL: URL,
        expectedSize: Int64,
        progress: @escaping @Sendable (_ bytesWritten: Int64, _ expectedSize: Int64) -> Void
    ) async throws {
        try await Task.detached {
            try performDecompression(inputURL: inputURL, outputURL: outputURL, expectedSize: expectedSize, progress: progress)
        }.value
    }

    // MARK: - Private

    private static func performCompression(
        inputURL: URL,
        outputURL: URL,
        progress: @escaping (_ bytesRead: Int64, _ totalBytes: Int64) -> Void
    ) throws {
        let inputSize = try fileSize(of: inputURL)
        logger.info("Compressing \(inputURL.lastPathComponent) (\(inputSize) bytes) with LZFSE")

        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inputHandle.close() }

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        let outputFilter = try OutputFilter(.compress, using: .lzfse, bufferCapacity: bufferSize) { data in
            if let data, !data.isEmpty {
                outputHandle.write(data)
            }
        }

        var bytesRead: Int64 = 0
        while let chunk = try inputHandle.read(upToCount: bufferSize), !chunk.isEmpty {
            try outputFilter.write(chunk)
            bytesRead += Int64(chunk.count)
            progress(bytesRead, inputSize)
        }

        try outputFilter.finalize()

        let compressedSize = try fileSize(of: outputURL)
        let ratio = inputSize > 0 ? Double(compressedSize) / Double(inputSize) * 100.0 : 0
        logger.info("Compression complete: \(compressedSize) bytes (\(String(format: "%.1f", ratio))% of original)")
    }

    private static func performDecompression(
        inputURL: URL,
        outputURL: URL,
        expectedSize: Int64,
        progress: @escaping (_ bytesWritten: Int64, _ expectedSize: Int64) -> Void
    ) throws {
        logger.info("Decompressing \(inputURL.lastPathComponent), expected size: \(expectedSize) bytes")

        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inputHandle.close() }

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        var bytesWritten: Int64 = 0

        let outputFilter = try OutputFilter(.decompress, using: .lzfse, bufferCapacity: bufferSize) { data in
            if let data, !data.isEmpty {
                outputHandle.write(data)
                bytesWritten += Int64(data.count)
                progress(bytesWritten, expectedSize)
            }
        }

        while let chunk = try inputHandle.read(upToCount: bufferSize), !chunk.isEmpty {
            try outputFilter.write(chunk)
        }

        try outputFilter.finalize()

        logger.info("Decompression complete: \(bytesWritten) bytes written")
    }

    static func fileSize(of url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return Int64(attrs[.size] as? UInt64 ?? 0)
    }
}
