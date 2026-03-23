//
//  DiskImageGenerator.swift
//  VirtualCore
//
//  Created by Guilherme Rambo on 19/07/22.
//

import Foundation

fileprivate extension VBManagedDiskImage.Format {
    var hdiutilType: String {
        switch self {
        case .raw:
            assertionFailure(".raw not supported with hdiutil")
            return "UDIF"
        case .dmg:
            return "UDIF"
        case .sparse:
            return "SPARSE"
        case .asif:
            return "ASIF"
        }
    }
}

public final class DiskImageGenerator {
    private enum ImageInfoKeys {
        static let sizeInformation = "Size Information"
        static let sizeInfo = "Size Info"
        static let totalBytes = "Total Bytes"
    }

    public struct ImageSettings {
        public var url: URL
        public var template: VBManagedDiskImage
        public var preinitializeFilesystem = false
        
        public init(for image: VBManagedDiskImage, in vm: VBVirtualMachine) {
            self.url = vm.diskImageURL(for: image)
            self.template = image
        }

        public init(for device: VBStorageDevice, in vm: VBVirtualMachine) throws {
            guard case .managedImage(let image) = device.backing else {
                throw Failure("Only managed disk images can be created.")
            }

            self.url = vm.diskImageURL(for: image)
            self.template = image
            self.preinitializeFilesystem = !device.isBootVolume && vm.configuration.systemType == .mac
        }
    }

    public static func generateImage(with settings: ImageSettings) async throws {
        guard settings.template.format.isSupported else {
            throw "Unsupported disk image format \(settings.template.format.hdiutilType.quoted)."
        }

        switch settings.template.format {
        case .raw:
            try await generateRaw(with: settings)
        case .dmg, .sparse:
            try await generateDMG(with: settings)
        case .asif:
            try await generateBlankASIF(with: settings)
        }
    }

    public static func resizeImage(at url: URL, to size: UInt64) async throws {
        try await diskutil(arguments: [
            "image",
            "resize",
            "--size",
            "\(size)b",
            url.path
        ])
    }

    public static func currentLogicalSize(of image: VBManagedDiskImage, at url: URL) throws -> UInt64 {
        switch image.format {
        case .raw:
            guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 else {
                throw Failure("Failed to determine the size of \(url.lastPathComponent).")
            }
            return size
        case .dmg, .sparse, .asif:
            let data = try runCommandSync("/usr/bin/hdiutil", with: ["imageinfo", "-plist", url.path])
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]

            let sizeContainer = (plist?[ImageInfoKeys.sizeInformation] as? [String: Any])
                ?? (plist?[ImageInfoKeys.sizeInfo] as? [String: Any])

            if let size = sizeContainer?[ImageInfoKeys.totalBytes] as? UInt64 {
                return size
            } else if let size = sizeContainer?[ImageInfoKeys.totalBytes] as? NSNumber {
                return size.uint64Value
            } else {
                throw Failure("Failed to determine the size of \(url.lastPathComponent).")
            }
        }
    }

    private static func generateRaw(with settings: ImageSettings) async throws {
        if settings.preinitializeFilesystem {
            try await diskutil(arguments: [
                "image",
                "create",
                "blank",
                "--format",
                "RAW",
                "--size",
                "\(settings.template.size)b",
                "--volumeName",
                settings.template.filename,
                settings.url.path
            ])
            return
        }

        let diskFd = open(settings.url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        if diskFd == -1 {
            throw Failure("Cannot create disk image.")
        }

        var result = ftruncate(diskFd, off_t(settings.template.size))
        if result != 0 {
            throw Failure("ftruncate() failed.")
        }

        result = close(diskFd)
        if result != 0 {
            throw Failure("Failed to close the disk image.")
        }
    }

    private static func generateDMG(with settings: ImageSettings) async throws {
        try await hdiutil(arguments: [
            "create",
            "-layout",
            "GPTSPUD",
            "-type",
            settings.template.format.hdiutilType,
            "-megabytes",
            "\(settings.template.size / .storageMegabyte)",
            "-fs",
            "APFS",
            "-volname",
            settings.template.filename,
            "-nospotlight",
            settings.url.path
        ])
    }

    private static func generateBlankASIF(with settings: ImageSettings) async throws {
        try await diskutil(arguments: [
            "image",
            "create",
            "blank",
            "--fs",
            "none",
            "--format",
            settings.template.format.hdiutilType,
            "--size",
            "\(settings.template.size / .storageGigabyte)G",
            settings.url.path
        ])
    }

    private static func hdiutil(arguments: [String]) async throws {
        try await runCommand("/usr/bin/hdiutil", with: arguments)
    }

    private static func diskutil(arguments: [String]) async throws {
        try await runCommand("/usr/sbin/diskutil", with: arguments)
    }

    private static func runCommand(_ path: String, with arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        #if DEBUG
        print("💻 \(path) arguments: \(process.arguments!.joined(separator: " "))")
        #endif

        let err = Pipe()
        let out = Pipe()
        process.standardError = err
        process.standardOutput = out
        try process.run()

        var error = ""
        for try await line in err.fileHandleForReading.bytes.lines {
            error.append("\(line)\n")
        }

        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return }

        if error.trimmingCharacters(in: .newlines).count > 0 {
            throw Failure(error)
        } else {
            throw Failure("Command \(path) failed with exit code \(process.terminationStatus)")
        }
    }

    private static func runCommandSync(_ path: String, with arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let err = Pipe()
        let out = Pipe()
        process.standardError = err
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()

        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        let error = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            if !error.isEmpty {
                throw Failure(error)
            } else {
                throw Failure("Command \(path) failed with exit code \(process.terminationStatus)")
            }
        }

        return output
    }

}
