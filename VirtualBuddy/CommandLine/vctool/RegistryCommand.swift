import Foundation
import ArgumentParser
import VirtualCore

struct RegistryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "registry",
        abstract: "Push, pull, and manage OCI registry images.",
        subcommands: [
            PushCommand.self,
            PullCommand.self,
            ListCommand.self,
            LoginCommand.self,
        ]
    )

    // MARK: - Push

    struct PushCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "push",
            abstract: "Push an IPSW file or VM bundle to an OCI registry."
        )

        @Argument(help: "Path to the IPSW file or .vbvm bundle to push.")
        var path: String

        @Option(name: .long, help: "OCI reference to push to (e.g., ghcr.io/org/repo:tag).")
        var to: String

        @Option(name: .long, help: "Registry authentication token (PAT). Can also be set via VIRTUALBUDDY_REGISTRY_TOKEN env var.")
        var token: String?

        @Option(name: .long, help: "User-facing name for the image (e.g., \"macOS 15.2\").")
        var name: String?

        @Option(name: .long, help: "Build identifier (e.g., \"24C101\"). Auto-detected from IPSW if not specified.")
        var build: String?

        @Option(name: .long, help: "OS version (e.g., \"15.2\"). Auto-detected from IPSW if not specified.")
        var version: String?

        @Flag(name: .long, help: "Force treating the path as a VM bundle.")
        var bundle: Bool = false

        func run() async throws {
            let sourceURL = URL(filePath: path.resolvedPath)
            let reference = try OCIReference(parsing: to)

            // Resolve token
            let resolvedToken = try resolveToken(token)
            let credentialStore = OCICredentialStore()
            if let resolvedToken {
                try credentialStore.store(.pat(resolvedToken), for: reference.registry)
            }

            let authHandler = OCIAuthHandler(credentialStore: credentialStore)
            let pushClient = OCIPushClient(authHandler: authHandler)

            // Determine if this is a bundle or IPSW
            let isBundle = bundle || sourceURL.pathExtension == VBVirtualMachine.bundleExtension || sourceURL.isExistingDirectory

            if isBundle {
                try await pushBundle(sourceURL: sourceURL, reference: reference, pushClient: pushClient)
            } else {
                try await pushIPSW(sourceURL: sourceURL, reference: reference, pushClient: pushClient)
            }
        }

        private func pushIPSW(sourceURL: URL, reference: OCIReference, pushClient: OCIPushClient) async throws {
            let ipswURL = try sourceURL.ensureExistingFile()

            let metadata = VBImageMetadata(
                build: build ?? reference.tag ?? "unknown",
                version: version ?? "unknown",
                name: name ?? ipswURL.deletingPathExtension().lastPathComponent
            )

            fputs("Pushing \(ipswURL.lastPathComponent) to \(reference.description)...\n", stderr)

            var lastPhase: OCIProgress.Phase?

            try await pushClient.push(
                reference: reference,
                ipswURL: ipswURL,
                metadata: metadata
            ) { progress in
                if progress.phase != lastPhase {
                    lastPhase = progress.phase
                    switch progress.phase {
                    case .hashing:
                        fputs("\nHashing IPSW...\n", stderr)
                    case .uploading:
                        fputs("\nUploading...\n", stderr)
                    case .pushingManifest:
                        fputs("\nPushing manifest...\n", stderr)
                    default:
                        break
                    }
                }

                if progress.totalBytes > 0 {
                    let percent = Int(progress.fractionCompleted * 100)
                    let mb = progress.bytesCompleted / (1024 * 1024)
                    let totalMB = progress.totalBytes / (1024 * 1024)
                    fputs("\r  \(percent)%  \(mb)/\(totalMB) MB", stderr)
                }
            }

            fputs("\n\n✅ Push complete: \(reference.description)\n", stderr)
        }

        private func pushBundle(sourceURL: URL, reference: OCIReference, pushClient: OCIPushClient) async throws {
            guard sourceURL.isExistingDirectory else {
                throw "Path is not a directory: \(sourceURL.path)"
            }

            fputs("Pushing VM bundle \(sourceURL.lastPathComponent) to \(reference.description)...\n", stderr)

            let bundlePushClient = OCIVMBundlePushClient(pushClient: pushClient)

            var lastPhase: OCIProgress.Phase?

            try await bundlePushClient.pushBundle(
                bundleURL: sourceURL,
                reference: reference
            ) { progress in
                if progress.phase != lastPhase {
                    lastPhase = progress.phase
                    switch progress.phase {
                    case .compressing:
                        fputs("\nCompressing disk images...\n", stderr)
                    case .hashing:
                        fputs("\nHashing...\n", stderr)
                    case .uploading:
                        fputs("\nUploading...\n", stderr)
                    case .pushingManifest:
                        fputs("\nPushing manifest...\n", stderr)
                    default:
                        break
                    }
                }

                if progress.totalBytes > 0 {
                    let percent = Int(progress.fractionCompleted * 100)
                    let mb = progress.bytesCompleted / (1024 * 1024)
                    let totalMB = progress.totalBytes / (1024 * 1024)
                    fputs("\r  \(percent)%  \(mb)/\(totalMB) MB", stderr)
                }
            }

            fputs("\n\n✅ Bundle push complete: \(reference.description)\n", stderr)
        }
    }

    // MARK: - Pull

    struct PullCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pull",
            abstract: "Pull an IPSW or VM bundle from an OCI registry."
        )

        @Argument(help: "OCI reference to pull (e.g., ghcr.io/org/repo:tag).")
        var reference: String

        @Option(name: .long, help: "Output directory for the downloaded file.")
        var output: String = "."

        @Option(name: .long, help: "Registry authentication token (PAT).")
        var token: String?

        @Flag(name: .long, help: "Place the VM bundle directly in VirtualBuddy's library path.")
        var library: Bool = false

        func run() async throws {
            let ref = try OCIReference(parsing: reference)

            let resolvedToken = try resolveToken(token)
            let credentialStore = OCICredentialStore()
            if let resolvedToken {
                try credentialStore.store(.pat(resolvedToken), for: ref.registry)
            }

            let authHandler = OCIAuthHandler(credentialStore: credentialStore)
            let pullClient = OCIPullClient(authHandler: authHandler)

            fputs("Pulling \(ref.description)...\n", stderr)

            // Fetch manifest to detect artifact type
            let manifest = try await pullClient.pullManifest(reference: ref)
            let isVMBundle = manifest.config.mediaType == OCIMediaType.vmBundleConfig

            if isVMBundle {
                try await pullVMBundle(ref: ref, manifest: manifest, pullClient: pullClient, authHandler: authHandler)
            } else {
                try await pullIPSW(ref: ref, pullClient: pullClient)
            }
        }

        private func pullIPSW(ref: OCIReference, pullClient: OCIPullClient) async throws {
            let outputDir = try output.resolvedURL.ensureExistingDirectory(createIfNeeded: true)

            var lastPhase: OCIProgress.Phase?

            let localURL = try await pullClient.pull(
                reference: ref,
                destinationDirectory: outputDir
            ) { progress in
                if progress.phase != lastPhase {
                    lastPhase = progress.phase
                    switch progress.phase {
                    case .fetchingManifest:
                        fputs("Fetching manifest...\n", stderr)
                    case .downloading:
                        fputs("Downloading...\n", stderr)
                    case .verifying:
                        fputs("\nVerifying...\n", stderr)
                    default:
                        break
                    }
                }

                if progress.phase == .downloading, progress.totalBytes > 0 {
                    let percent = Int(progress.fractionCompleted * 100)
                    let mb = progress.bytesCompleted / (1024 * 1024)
                    let totalMB = progress.totalBytes / (1024 * 1024)
                    fputs("\r  \(percent)%  \(mb)/\(totalMB) MB", stderr)
                }
            }

            fputs("\n✅ Downloaded to: \(localURL.path)\n", stderr)
            print(localURL.path)
        }

        private func pullVMBundle(ref: OCIReference, manifest: OCIManifest, pullClient: OCIPullClient, authHandler: OCIAuthHandler) async throws {
            let outputDir: URL
            if library {
                // Use VirtualBuddy's default VM library path
                let libraryPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("VirtualBuddy")
                try FileManager.default.createDirectory(at: libraryPath, withIntermediateDirectories: true)
                outputDir = libraryPath
            } else {
                outputDir = try output.resolvedURL.ensureExistingDirectory(createIfNeeded: true)
            }

            fputs("Detected VM bundle artifact.\n", stderr)

            let bundlePullClient = OCIVMBundlePullClient(pullClient: pullClient, authHandler: authHandler)

            var lastPhase: OCIProgress.Phase?

            let bundleURL = try await bundlePullClient.pullBundle(
                reference: ref,
                destinationDirectory: outputDir,
                existingManifest: manifest
            ) { progress in
                if progress.phase != lastPhase {
                    lastPhase = progress.phase
                    switch progress.phase {
                    case .fetchingManifest:
                        fputs("Fetching manifest...\n", stderr)
                    case .downloading:
                        fputs("Downloading layers...\n", stderr)
                    case .decompressing:
                        fputs("\nDecompressing disk images...\n", stderr)
                    case .verifying:
                        fputs("\nVerifying...\n", stderr)
                    case .assembling:
                        fputs("Assembling VM bundle...\n", stderr)
                    default:
                        break
                    }
                }

                if progress.totalBytes > 0 {
                    let percent = Int(progress.fractionCompleted * 100)
                    let mb = progress.bytesCompleted / (1024 * 1024)
                    let totalMB = progress.totalBytes / (1024 * 1024)
                    fputs("\r  \(percent)%  \(mb)/\(totalMB) MB", stderr)
                }
            }

            fputs("\n✅ VM bundle assembled at: \(bundleURL.path)\n", stderr)
            if library {
                fputs("The VM should appear in VirtualBuddy's library automatically.\n", stderr)
            }
            print(bundleURL.path)
        }
    }

    // MARK: - List

    struct ListCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List available tags in an OCI registry repository."
        )

        @Argument(help: "Repository reference (e.g., ghcr.io/org/repo).")
        var repository: String

        @Option(name: .long, help: "Registry authentication token (PAT).")
        var token: String?

        func run() async throws {
            let ref = try OCIReference(parsing: repository.contains(":") ? repository : "\(repository):latest")

            let resolvedToken = try resolveToken(token)
            let credentialStore = OCICredentialStore()
            if let resolvedToken {
                try credentialStore.store(.pat(resolvedToken), for: ref.registry)
            }

            let authHandler = OCIAuthHandler(credentialStore: credentialStore)
            let bearerToken = try await authHandler.token(for: ref, action: "pull")

            // Fetch tags list
            var request = URLRequest(url: ref.tagsListURL)
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw OCIError.httpError(statusCode: code, body: String(data: data, encoding: .utf8))
            }

            struct TagsList: Decodable {
                var name: String?
                var tags: [String]?
            }

            let tagsList = try JSONDecoder().decode(TagsList.self, from: data)
            let tags = tagsList.tags ?? []

            if tags.isEmpty {
                fputs("No tags found in \(ref.registry)/\(ref.repository)\n", stderr)
            } else {
                fputs("Tags in \(ref.registry)/\(ref.repository):\n\n", stderr)
                for tag in tags {
                    print(tag)
                }
            }
        }
    }

    // MARK: - Login

    struct LoginCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "login",
            abstract: "Store registry credentials in the Keychain."
        )

        @Argument(help: "Registry hostname (e.g., ghcr.io).")
        var registry: String

        @Option(name: .long, help: "Authentication token (PAT).")
        var token: String

        @Option(name: .long, help: "Username (default: virtualbuddy).")
        var username: String = "virtualbuddy"

        func run() async throws {
            let credentialStore = OCICredentialStore()
            try credentialStore.store(OCICredential(username: username, password: token), for: registry)
            fputs("✅ Credentials stored for \(registry)\n", stderr)
        }
    }
}

// MARK: - Helpers

private func resolveToken(_ explicitToken: String?) throws -> String? {
    if let explicitToken {
        return explicitToken
    }
    if let envToken = ProcessInfo.processInfo.environment["VIRTUALBUDDY_REGISTRY_TOKEN"] {
        return envToken
    }
    return nil
}
