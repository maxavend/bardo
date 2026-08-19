enum AudioSource: String, Codable, CaseIterable, Sendable {
    case microphone
    case systemAudio
    case importedFile
}
