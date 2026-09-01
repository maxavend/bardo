import Foundation

actor MeetingMinutesStore {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    static func live() throws -> MeetingMinutesStore {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let rootURL = applicationSupport
            .appendingPathComponent("Bardo", isDirectory: true)
            .appendingPathComponent("MeetingMinutes", isDirectory: true)
        return MeetingMinutesStore(rootURL: rootURL)
    }

    func load(recordingID: Recording.ID) throws -> MeetingMinutes? {
        let url = fileURL(for: recordingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MeetingMinutes.self, from: data)
    }

    func save(_ minutes: MeetingMinutes) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(minutes)
        try data.write(to: fileURL(for: minutes.recordingID), options: .atomic)
    }

    func delete(recordingID: Recording.ID) throws {
        let url = fileURL(for: recordingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(for recordingID: Recording.ID) -> URL {
        rootURL
            .appendingPathComponent(recordingID.uuidString)
            .appendingPathExtension("json")
    }
}
