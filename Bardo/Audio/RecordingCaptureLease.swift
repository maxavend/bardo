import Foundation

@MainActor
enum RecordingCaptureLease {
    private static var ownerID: UUID?

    static func acquire(ownerID: UUID) -> Bool {
        guard self.ownerID == nil || self.ownerID == ownerID else { return false }
        self.ownerID = ownerID
        return true
    }

    static func release(ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        self.ownerID = nil
    }
}
