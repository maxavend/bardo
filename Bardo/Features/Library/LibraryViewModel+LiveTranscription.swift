extension LibraryViewModel {
    convenience init() {
        self.init(transcriber: try? BardoTranscriptionService.live())
    }
}
