import Foundation

actor MeetingMinutesStore {
    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    static func live(fileManager: FileManager = .default) throws -> MeetingMinutesStore {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let rootURL = applicationSupport
            .appendingPathComponent("Bardo", isDirectory: true)
            .appendingPathComponent("MeetingMinutes", isDirectory: true)
        return MeetingMinutesStore(rootURL: rootURL, fileManager: fileManager)
    }

    func load(recordingID: Recording.ID) throws -> MeetingMinutes? {
        let url = fileURL(for: recordingID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MeetingMinutes.self, from: data)
    }

    func save(_ minutes: MeetingMinutes) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(minutes)
        try data.write(to: fileURL(for: minutes.recordingID), options: .atomic)
    }

    func delete(recordingID: Recording.ID) throws {
        let url = fileURL(for: recordingID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func fileURL(for recordingID: Recording.ID) -> URL {
        rootURL
            .appendingPathComponent(recordingID.uuidString)
            .appendingPathExtension("json")
    }
}
