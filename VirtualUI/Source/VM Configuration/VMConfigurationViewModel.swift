//
//  VMConfigurationViewModel.swift
//  VirtualUI
//
//  Created by Guilherme Rambo on 18/07/22.
//

import SwiftUI
import VirtualCore

public enum VMConfigurationContext: Int {
    case preInstall
    case postInstall
}

public final class VMConfigurationViewModel: ObservableObject {
    
    @Published var config: VBMacConfiguration {
        didSet {
            /// Reset display preset when changing display settings.
            /// This is so the warning goes away, if any warning is being shown.
            if config.hardware.displayDevices != oldValue.hardware.displayDevices,
               config.hardware.displayDevices.first != selectedDisplayPreset?.device
            {
                selectedDisplayPreset = nil
            }
        }
    }
    
    @Published public internal(set) var supportState: VBMacConfiguration.SupportState = .supported

    @Published public internal(set) var resolvedRestoreImage: ResolvedRestoreImage? {
        didSet {
            applyResolvedFeatureDefaultsIfNeeded()
        }
    }
    
    @Published var selectedDisplayPreset: VBDisplayPreset?
    
    @Published private(set) var vm: VBVirtualMachine

    public let canResizeExistingBootDisk: Bool

    public let context: VMConfigurationContext
    
    public init(_ vm: VBVirtualMachine, context: VMConfigurationContext = .postInstall, resolvedRestoreImage: ResolvedRestoreImage? = nil, canResizeExistingBootDisk: Bool = false) {
        self.config = vm.configuration
        self.vm = vm
        self.context = context
        self.resolvedRestoreImage = resolvedRestoreImage
        self.canResizeExistingBootDisk = canResizeExistingBootDisk

        syncBootDiskSizeFromDiskIfNeeded()
        
        applyResolvedFeatureDefaultsIfNeeded()

        Task { await validate() }
    }

    @discardableResult
    public func validate() async -> VBMacConfiguration.SupportState {
        let updatedState = await config.validate(for: vm, skipVirtualizationConfig: context == .preInstall)

        await MainActor.run {
            supportState = updatedState
        }

        return updatedState
    }
    
    public func createImage(for device: VBStorageDevice) async throws {
        let settings = try DiskImageGenerator.ImageSettings(for: device, in: vm)
        
        try await DiskImageGenerator.generateImage(with: settings)
    }

    public func commitStorageChangesIfNeeded() async throws {
        guard context == .postInstall else { return }
        guard canResizeExistingBootDisk else { return }
        guard vm.configuration.systemType == .mac else { return }

        let currentBootImage = try vm.bootDiskImage
        let updatedBootImage = try config.hardware.bootManagedDiskImage

        guard updatedBootImage.size != currentBootImage.size else { return }
        guard updatedBootImage.size > currentBootImage.size else {
            throw Failure("Shrinking an existing boot disk is not supported.")
        }
        guard !vm.hasSavedStates(in: VBSettings.current.libraryURL) else {
            throw Failure("Remove saved states for this virtual machine before increasing the boot disk size.")
        }

        let bootDiskURL = vm.diskImageURL(for: currentBootImage)
        guard FileManager.default.fileExists(atPath: bootDiskURL.path) else {
            throw Failure("The boot disk image could not be found at \(bootDiskURL.path)")
        }

        try await DiskImageGenerator.resizeImage(at: bootDiskURL, to: updatedBootImage.size)

        await MainActor.run {
            vm.configuration = config
        }
    }

    public func updateBootStorageDevice(with image: VBManagedDiskImage) {
        guard let idx = config.hardware.storageDevices.firstIndex(where: { $0.isBootVolume }) else {
            fatalError("Missing boot device in VM configuration")
        }

        var device = config.hardware.storageDevices[idx]
        device.backing = .managedImage(image)
        config.hardware.addOrUpdate(device)
    }
    
}

// MARK: - Feature Defaults

private extension VMConfigurationViewModel {
    func syncBootDiskSizeFromDiskIfNeeded() {
        guard context == .postInstall else { return }
        guard vm.configuration.systemType == .mac else { return }

        guard let bootDeviceIndex = config.hardware.storageDevices.firstIndex(where: { $0.isBootVolume }) else {
            return
        }
        guard case .managedImage(let image) = config.hardware.storageDevices[bootDeviceIndex].backing else {
            return
        }

        let diskURL = vm.diskImageURL(for: image)
        guard FileManager.default.fileExists(atPath: diskURL.path) else { return }
        guard let actualSize = try? DiskImageGenerator.currentLogicalSize(of: image, at: diskURL) else { return }
        guard actualSize != image.size else { return }

        var updatedImage = image
        updatedImage.size = actualSize

        var updatedDevice = config.hardware.storageDevices[bootDeviceIndex]
        updatedDevice.backing = .managedImage(updatedImage)
        config.hardware.addOrUpdate(updatedDevice)
    }

    func applyResolvedFeatureDefaultsIfNeeded() {
        guard context == .preInstall else { return }
        guard let resolvedRestoreImage else { return }

        var updated = config

        if resolvedRestoreImage.feature(id: CatalogFeatureID.guestApp)?.status.isUnsupported == true {
            updated.guestAdditionsEnabled = false
        }

        if resolvedRestoreImage.feature(id: CatalogFeatureID.trackpad)?.status.isUnsupported == true,
           updated.hardware.pointingDevice.kind == .trackpad
        {
            updated.hardware.pointingDevice.kind = .mouse
        }

        if resolvedRestoreImage.feature(id: CatalogFeatureID.macKeyboard)?.status.isUnsupported == true,
           updated.hardware.keyboardDevice.kind == .mac
        {
            updated.hardware.keyboardDevice.kind = .generic
        }

        if resolvedRestoreImage.feature(id: CatalogFeatureID.displayResize)?.status.isUnsupported == true {
            updated.hardware.displayDevices = updated.hardware.displayDevices.map { device in
                var updatedDevice = device
                updatedDevice.automaticallyReconfiguresDisplay = false
                return updatedDevice
            }
        }

        if resolvedRestoreImage.feature(id: CatalogFeatureID.rosettaSharing)?.status.isUnsupported == true {
            updated.rosettaSharingEnabled = false
        }

        if updated != config {
            config = updated
        }
    }
}

extension VBMacDevice {
    var bootManagedDiskImage: VBManagedDiskImage {
        get throws {
            guard let device = storageDevices.first(where: { $0.isBootVolume }) else {
                throw Failure("Missing boot storage device.")
            }

            guard case .managedImage(let image) = device.backing else {
                throw Failure("The boot storage device must use a VirtualBuddy-managed disk image.")
            }

            return image
        }
    }
}
