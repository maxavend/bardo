import Foundation

/// Stands in for the sharing picker when the backend hears the whole Mac: there is
/// nothing to choose, so presenting it selects everything straight away.
@MainActor
final class WholeSystemAudioSelection: SystemContentSelecting {
    var eventHandler: ((SystemContentSelectionEvent) -> Void)?
    private var isActive = false

    func present() {
        let isUpdate = isActive
        isActive = true
        eventHandler?(.selected(.entireSystem, isUpdate: isUpdate))
    }

    func deactivate() {
        isActive = false
    }
}
