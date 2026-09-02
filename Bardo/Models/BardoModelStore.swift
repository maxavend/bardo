import Foundation

enum BardoModelStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidPrivateRoot
    case invalidModelRoot(ManagedModel)
    case modelRootIsNotDirectory(ManagedModel)

    var errorDescription: String? {
        switch self {
        case .invalidPrivateRoot:
            return "Bardo's private model root must not resolve through a symbolic link."
        case .invalidModelRoot(let model):
            return "The managed root for \(model.rawValue) is outside Bardo's model root."
        case .modelRootIsNotDirectory(let model):
            return "The managed root for \(model.rawValue) is not a directory."
        }
    }
}

struct BardoModelStore {
    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    static func live() throws -> BardoModelStore {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let root = applicationSupport
            .appendingPathComponent("Bardo", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        let store = BardoModelStore(rootURL: root)
        _ = try store.validatePrivateRoot()
        return store
    }

    func root(for model: ManagedModel) -> URL {
        rootURL.appendingPathComponent(directoryName(for: model), isDirectory: true)
    }

    func reset(_ model: ManagedModel) throws {
        _ = try validatePrivateRoot()
        let modelRoot = try validatedRoot(for: model)
        guard fileManager.fileExists(atPath: modelRoot.path) else { return }

        let values = try modelRoot.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw BardoModelStoreError.modelRootIsNotDirectory(model)
        }

        try fileManager.removeItem(at: modelRoot)
    }

    private func validatedRoot(for model: ManagedModel) throws -> URL {
        let expectedRoot = root(for: model).standardizedFileURL
        let standardizedRoot = try validatePrivateRoot()
        let resolvedRoot = standardizedRoot
        let resolvedModelRoot = expectedRoot.resolvingSymlinksInPath()

        guard expectedRoot.deletingLastPathComponent() == standardizedRoot,
              expectedRoot != standardizedRoot,
              resolvedModelRoot.pathComponents.starts(with: resolvedRoot.pathComponents)
        else {
            throw BardoModelStoreError.invalidModelRoot(model)
        }

        return expectedRoot
    }

    private func validatePrivateRoot() throws -> URL {
        let standardizedRoot = rootURL.standardizedFileURL
        guard standardizedRoot.resolvingSymlinksInPath() == standardizedRoot else {
            throw BardoModelStoreError.invalidPrivateRoot
        }
        return standardizedRoot
    }

    private func directoryName(for model: ManagedModel) -> String {
        switch model {
        case .whisperBalanced:
            return "whisper-balanced"
        case .whisperMaximumAccuracy:
            return "whisper-maximum-accuracy"
        case .parakeet:
            return "parakeet"
        case .speakerKit:
            return "speaker-kit"
        case .qwen:
            return "qwen"
        }
    }
}
