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

/// Recoveries in progress. Quitting waits for them, because a recovery moves audio into
/// the Library and should not stop halfway.
@MainActor
enum CaptureRecoveryActivity {
    private(set) static var activeCount = 0

    static var isActive: Bool { activeCount > 0 }

    static func begin() {
        activeCount += 1
    }

    static func end() {
        activeCount = max(0, activeCount - 1)
    }
}
