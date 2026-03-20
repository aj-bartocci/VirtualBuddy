import Foundation

@MainActor
public extension VMLibraryController {

    nonisolated static let savedStateDirectoryName = "_SavedState"

    var savedStatesDirectoryURL: URL {
        self.libraryURL.appending(path: Self.savedStateDirectoryName, directoryHint: .isDirectory)
    }

    func savedStatesLibraryURLCreatingIfNeeded() throws -> URL {
        try savedStatesDirectoryURL.creatingDirectoryIfNeeded()
    }

    func savedStateDirectoryURL(for model: VBVirtualMachine) -> URL {
        savedStatesDirectoryURL
            .appending(path: model.metadata.uuid.uuidString, directoryHint: .isDirectory)
    }

    func savedStateDirectoryURLCreatingIfNeeded(for model: VBVirtualMachine) throws -> URL {
        try savedStateDirectoryURL(for: model)
            .creatingDirectoryIfNeeded()
    }

    func hasSavedStates(for model: VBVirtualMachine) -> Bool {
        model.hasSavedStates(in: libraryURL)
    }

    func createSavedStatePackage(for model: VBVirtualMachine, snapshotName name: String) throws -> VBSavedStatePackage {
        let baseURL = try model.savedStatesDirectoryURLCreatingIfNeeded(in: self)

        return try VBSavedStatePackage(creatingPackageInDirectoryAt: baseURL, model: model, snapshotName: name)
    }

    func virtualMachine(with uuid: UUID) throws -> VBVirtualMachine {
        guard let model = virtualMachines.first(where: { $0.metadata.uuid == uuid }) else {
            throw Failure("Virtual machine not found with UUID \(uuid)")
        }
        return model
    }

    func virtualMachineURL(forSavedStatePackageURL url: URL) throws -> URL {
        try virtualMachine(forSavedStatePackageURL: url).bundleURL
    }

    func virtualMachine(forSavedStatePackageURL url: URL) throws -> VBVirtualMachine {
        let metadata = try VBSavedStateMetadata(packageAt: url)
        let model = try virtualMachine(forSavedStateMetadata: metadata)
        return model
    }

    func virtualMachine(forSavedStateMetadata metadata: VBSavedStateMetadata) throws -> VBVirtualMachine {
        try virtualMachine(with: metadata.vmUUID)
    }
}

public extension VBVirtualMachine {
    func hasSavedStates(in libraryURL: URL) -> Bool {
        let directoryURL = libraryURL
            .appending(path: VMLibraryController.savedStateDirectoryName, directoryHint: .isDirectory)
            .appending(path: metadata.uuid.uuidString, directoryHint: .isDirectory)

        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants, .skipsSubdirectoryDescendants, .skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return false
        }

        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == VBSavedStatePackage.fileExtension {
                return true
            }
        }

        return false
    }
}
