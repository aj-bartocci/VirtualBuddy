import SwiftUI
import VirtualCore
import Combine
import OSLog

enum RestoreImageSelectionFocus: Hashable {
    case groups
    case images
}

extension VBAPIClient {
    static let shared = VBAPIClient()
}

@MainActor
final class RestoreImageSelectionController: ObservableObject {

    /// If loading takes less than this amount of time, then the controller will never even set the `isLoading` property.
    private static let minLoadingTimeInMilliseconds = 100

    private let logger = Logger(subsystem: VirtualUIConstants.subsystemName, category: String(describing: RestoreImageSelectionController.self))

    init() {
        $selectedGroup.removeDuplicates().sink { [weak self] group in
            guard let self else { return }
            guard let group else { return }

            /// Selected group has changed, update available channel groups, images, and selected image.
            let updatedChannelGroups = ChannelGroup.groups(with: group.restoreImages)
            channelGroups = updatedChannelGroups
            images = updatedChannelGroups.flatMap(\.images)
            selectedRestoreImage = updatedChannelGroups.first?.images.first
        }
        .store(in: &cancellables)
    }

    private lazy var api = VBAPIClient.shared

    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var catalog: ResolvedCatalog?
    @Published private(set) var channelGroups: [ChannelGroup] = []
    @Published private(set) var images: [ResolvedRestoreImage] = []
    @Published var selectedGroup: ResolvedCatalogGroup?
    @Published var selectedRestoreImage: ResolvedRestoreImage?
    @Published var errorMessage: String?
    @Published var focusedElement = RestoreImageSelectionFocus.groups

    @Published private(set) var isLoading = false {
        didSet {
            if !isLoading {
                deferredLoadingTask?.cancel()
                deferredLoadingTask = nil
            }
        }
    }

    /// The controller will only set the`isLoading` property if loading takes a while.
    private var deferredLoadingTask: Task<Void, Never>?
    private func deferredStartLoading() {
        deferredLoadingTask?.cancel()
        deferredLoadingTask = Task { [weak self] in
            guard let self else { return }

            defer { deferredLoadingTask = nil }

            do {
                try await Task.sleep(for: .milliseconds(Self.minLoadingTimeInMilliseconds))

                logger.debug("Reached loading time delay, setting isLoading.")

                isLoading = true
            } catch { }
        }
    }

    private var inputCatalog: SoftwareCatalog?
    private var guestType = VBGuestType.mac

    func loadRestoreImageOptions(for guest: VBGuestType, skipCache: Bool = false) {
        logger.debug("Loading restore image options.")

        guestType = guest

        deferredStartLoading()

        Task {
            let start = ContinuousClock.now

            defer {
                logger.debug("Loading restore images took \(start.duration(to: .now).formatted(.units(allowed: [.milliseconds])), privacy: .public)")

                isLoading = false
            }

            do {
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "VBSimulateSlowCatalogFetch") {
                    logger.notice("⚠️ Delaying restore image options load due to VBSimulateSlowCatalogFetch debug flag!")
                    try await Task.sleep(for: .seconds(2))
                }
                #endif

                var catalog = try await api.fetchRestoreImages(for: guest, skipCache: skipCache)

                // Merge OCI registry images if configured
                catalog = await mergeOCIImages(into: catalog)

                inputCatalog = catalog

                await refreshResolvedCatalog(with: catalog)
            } catch {
                logger.error("Loading restore images failed - \(error, privacy: .public)")

                await MainActor.run {
                    self.catalog = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func mergeOCIImages(into catalog: SoftwareCatalog) async -> SoftwareCatalog {
        let config = OCIRegistryConfiguration.current

        guard config.isEnabled else { return catalog }

        do {
            let provider = OCICatalogProvider()
            let ociImages = try await provider.fetchImages(config: config)

            guard !ociImages.isEmpty else { return catalog }

            var merged = catalog

            // Add the OCI group and channel if not present
            if !merged.groups.contains(where: { $0.id == CatalogGroup.ociGroup.id }) {
                merged.groups.insert(.ociGroup, at: 0)
            }
            if !merged.channels.contains(where: { $0.id == CatalogChannel.ociChannel.id }) {
                merged.channels.append(.ociChannel)
            }
            if !merged.requirementSets.contains(where: { $0.id == RequirementSet.ociDefault.id }) {
                merged.requirementSets.append(.ociDefault)
            }

            // Add OCI images
            merged.restoreImages.append(contentsOf: ociImages)

            return merged
        } catch {
            logger.error("Failed to fetch OCI registry images: \(error, privacy: .public)")
            return catalog
        }
    }

    private func refreshResolvedCatalog(with catalog: SoftwareCatalog) async {
        logger.debug(#function)

        let platform: CatalogGuestPlatform = guestType == .linux ? .linux : .mac
        let resolved = ResolvedCatalog(environment: .current.guest(platform: platform), catalog: catalog)

        await MainActor.run {
            self.selectedGroup = resolved.groups.first(where: { $0.id == selectedGroup?.id }) ?? resolved.groups.first
            self.selectedRestoreImage = selectedGroup?.restoreImages.first(where: { $0.id == self.selectedRestoreImage?.id })
            self.catalog = resolved
        }
    }

    func deleteLocalDownload(for image: ResolvedRestoreImage) {
        logger.debug("Delete download requested for \(image.id)")

        /// Remove selection to force refresh of image browser.
        selectedRestoreImage = nil

        do {
            let fileURL = try image.localFileURL.require("File not found.")
            Task {
                do {
                    try await NSWorkspace.shared.recycle([fileURL])

                    if let inputCatalog {
                        await refreshResolvedCatalog(with: inputCatalog)
                    }
                } catch {
                    logger.error("Recycle failed for \(fileURL.path) - \(error, privacy: .public)")

                    NSApp.presentError(error)
                }
            }
        } catch {
            logger.error("Delete download failed for \(image.id) - \(error, privacy: .public)")

            NSApp.presentError(error)
        }
    }
}

extension ChannelGroup {
    static func groups(with restoreImages: [ResolvedRestoreImage]) -> [ChannelGroup] {
        var groupsByChannel = [CatalogChannel: ChannelGroup]()

        for image in restoreImages {
            /// Ensures images from each channel group are listed in the same order as the channels are ordered in the catalog.
            let order = groupsByChannel.keys.count

            groupsByChannel[image.channel, default: ChannelGroup(
                order: order,
                channel: image.channel,
                images: []
            )].images.append(image)
        }

        return groupsByChannel.values.sorted(by: { $0.order < $1.order })
    }
}
