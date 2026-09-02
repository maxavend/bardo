import Foundation

enum RecordingAction: Equatable, Sendable {
    case playPause
    case rename
    case moveToTrash
    case revealInFinder
    case copyManagedLocation
}

enum RecordingActionPolicy {
    static func actions(for recording: Recording) -> [RecordingAction] {
        var actions: [RecordingAction] = []
        if !recording.audioAssets.isEmpty {
            actions.append(.playPause)
        }
        actions.append(contentsOf: [.rename, .moveToTrash, .revealInFinder, .copyManagedLocation])
        return actions
    }

    static func allows(_ action: RecordingAction, for recording: Recording) -> Bool {
        actions(for: recording).contains(action)
    }
}
