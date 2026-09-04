import Foundation

enum MeetingMinutesModel {
    static let modelID = "mlx-community/LFM2.5-1.2B-Instruct-4bit"
    // Immutable Hugging Face snapshot. Do not point production builds at "main".
    static let modelRevision = "125e006d991147f3b432249d1bdf0821987f12b0"
    static let architecture = "lfm2"
    static let modelDirectoryName = "LFM2.5-1.2B-Instruct-4bit"
    static let bundledSubdirectory = "Models/Minutes"
    static let revisionMarkerFileName = ".bardo-model-revision"

    static func bundledURL(bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: modelDirectoryName,
            withExtension: nil,
            subdirectory: bundledSubdirectory
        )
    }
}


enum MeetingMinutesRuntimeReadiness {
    static let schemaVersion = 1

    private static var defaultsKey: String {
        "Bardo.MeetingMinutesRuntimeReady.v\(schemaVersion).\(MeetingMinutesModel.modelRevision)"
    }

    static func isReady(
        bundle: Bundle = .main,
        applicationSupportRoot: URL? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.bool(forKey: defaultsKey) else { return false }
        return MeetingMinutesModelResourceResolver.isInstalled(
            bundle: bundle,
            applicationSupportRoot: applicationSupportRoot,
            fileManager: fileManager
        )
    }

    static func markReady(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: defaultsKey)
    }

    static func invalidate(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

enum MeetingMinutesModelResourceResolver {
    static func managedRoot(applicationSupportRoot: URL? = nil) throws -> URL {
        if let applicationSupportRoot {
            return applicationSupportRoot.standardizedFileURL
        }
        return try BardoModelStore.live().root(for: .meetingMinutes)
    }

    static func resolve(
        bundle: Bundle = .main,
        applicationSupportRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        var candidates = [URL]()
        if let applicationSupportRoot {
            candidates.append(applicationSupportRoot)
        } else if let store = try? BardoModelStore.live() {
            candidates.append(store.root(for: .meetingMinutes))
        }
        if let bundled = MeetingMinutesModel.bundledURL(bundle: bundle) {
            candidates.append(bundled)
        }

        for candidate in candidates {
            if let snapshot = snapshotDirectory(in: candidate, fileManager: fileManager) {
                return snapshot
            }
        }

        throw MeetingMinutesError.modelFilesIncomplete(
            candidates.first ?? URL(fileURLWithPath: MeetingMinutesModel.bundledSubdirectory)
        )
    }

    static func isInstalled(
        bundle: Bundle = .main,
        applicationSupportRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        (try? resolve(
            bundle: bundle,
            applicationSupportRoot: applicationSupportRoot,
            fileManager: fileManager
        )) != nil
    }

    static func snapshotDirectory(
        in rootURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let root = rootURL.standardizedFileURL
        guard root.resolvingSymlinksInPath().standardizedFileURL == root else { return nil }

        if isCompleteSnapshot(root, inside: root, fileManager: fileManager) {
            return root
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "config.json" else { continue }
            let candidate = fileURL.deletingLastPathComponent().standardizedFileURL
            guard isContained(candidate, in: root),
                  isCompleteSnapshot(candidate, inside: root, fileManager: fileManager)
            else { continue }
            return candidate
        }

        return nil
    }

    private static func isCompleteSnapshot(
        _ directory: URL,
        inside root: URL,
        fileManager: FileManager
    ) -> Bool {
        guard isContained(directory, in: root),
              directory.resolvingSymlinksInPath().standardizedFileURL == directory
        else { return false }

        let config = directory.appendingPathComponent("config.json")
        let tokenizer = directory.appendingPathComponent("tokenizer.json")
        let tokenizerConfig = directory.appendingPathComponent("tokenizer_config.json")
        let revisionMarker = directory.appendingPathComponent(MeetingMinutesModel.revisionMarkerFileName)
        guard isRegularFile(config, fileManager: fileManager),
              isRegularFile(tokenizer, fileManager: fileManager)
                || isRegularFile(tokenizerConfig, fileManager: fileManager),
              isRegularFile(revisionMarker, fileManager: fileManager),
              let revision = try? String(contentsOf: revisionMarker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              revision == MeetingMinutesModel.modelRevision
        else { return false }

        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.contains { entry in
            let name = entry.lastPathComponent
            return isRegularFile(entry, fileManager: fileManager)
                && (name.hasSuffix(".safetensors") || name.hasSuffix(".safetensors.index.json"))
        }
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true
        else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        return resolvedCandidate.pathComponents.starts(with: resolvedRoot.pathComponents)
    }
}

struct MeetingMinutesModelManager: Sendable {
    private let modelRootURL: URL

    init(modelRootURL: URL) {
        self.modelRootURL = modelRootURL.standardizedFileURL
    }

    static func live() throws -> MeetingMinutesModelManager {
        MeetingMinutesModelManager(
            modelRootURL: try MeetingMinutesModelResourceResolver.managedRoot()
        )
    }

    func prepareForUse(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await MeetingMinutesModelDownloader.ensureAvailable(
            managedRoot: modelRootURL,
            progress: progress
        )
    }
}

enum MeetingMinutesModelDownloader {
    private struct HuggingFaceTreeEntry: Decodable {
        let path: String
        let type: String
    }

    static func ensureAvailable(
        managedRoot: URL,
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        if let existing = try? MeetingMinutesModelResourceResolver.resolve(
            bundle: bundle,
            applicationSupportRoot: managedRoot,
            fileManager: fileManager
        ) {
            progress(1)
            return existing
        }

        try Task.checkCancellation()
        let entries = try await listRemoteFiles()
        guard !entries.isEmpty else {
            throw MeetingMinutesError.modelNotAvailable("The Hugging Face model has no downloadable files.")
        }

        try fileManager.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let staging = managedRoot.appendingPathComponent(
            ".\(MeetingMinutesModel.modelDirectoryName).download-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        progress(0)
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let relativePath = try safeRelativePath(entry.path)
            let destination = staging.appendingPathComponent(relativePath, isDirectory: false)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await download(
                relativePath: relativePath,
                to: destination,
                fileManager: fileManager
            )
            progress(Double(index + 1) / Double(entries.count))
        }

        let revisionMarker = staging.appendingPathComponent(MeetingMinutesModel.revisionMarkerFileName)
        try Data(MeetingMinutesModel.modelRevision.utf8).write(to: revisionMarker, options: .atomic)

        guard MeetingMinutesModelResourceResolver.snapshotDirectory(
            in: staging,
            fileManager: fileManager
        ) != nil else {
            throw MeetingMinutesError.modelFilesIncomplete(staging)
        }

        let destination = managedRoot.appendingPathComponent(
            MeetingMinutesModel.modelDirectoryName,
            isDirectory: true
        )
        if let existing = try? MeetingMinutesModelResourceResolver.resolve(
            bundle: bundle,
            applicationSupportRoot: managedRoot,
            fileManager: fileManager
        ), existing.path != destination.path {
            return existing
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        guard let installed = MeetingMinutesModelResourceResolver.snapshotDirectory(
            in: managedRoot,
            fileManager: fileManager
        ) else {
            throw MeetingMinutesError.modelFilesIncomplete(destination)
        }
        progress(1)
        return installed
    }

    private static func listRemoteFiles() async throws -> [HuggingFaceTreeEntry] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(MeetingMinutesModel.modelID)/tree/\(MeetingMinutesModel.modelRevision)"
        components.queryItems = [
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "expand", value: "false")
        ]
        guard let url = components.url else {
            throw MeetingMinutesError.modelNotAvailable("The model download URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bardo-local-model-fetcher/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try JSONDecoder().decode([HuggingFaceTreeEntry].self, from: data)
            .filter { $0.type == "file" }
            .sorted { $0.path < $1.path }
    }

    private static func download(
        relativePath: String,
        to destination: URL,
        fileManager: FileManager
    ) async throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(MeetingMinutesModel.modelID)/resolve/\(MeetingMinutesModel.modelRevision)/\(relativePath)"
        components.queryItems = [URLQueryItem(name: "download", value: "true")]
        guard let url = components.url else {
            throw MeetingMinutesError.modelNotAvailable("The model file URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bardo-local-model-fetcher/1.0", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        try validate(response)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw MeetingMinutesError.modelNotAvailable("The model download request failed.")
        }
    }

    private static func safeRelativePath(_ path: String) throws -> String {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !value.hasPrefix("/"),
              !components.contains(where: { $0 == ".." || $0 == "." }) else {
            throw MeetingMinutesError.modelNotAvailable("The model returned an unsafe file path.")
        }
        return components.joined(separator: "/")
    }
}
