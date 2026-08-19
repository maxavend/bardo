import Foundation
import ScreenCaptureKit

final class ScreenCapturePickerCoordinator: NSObject, SystemContentSelecting, SCContentSharingPickerObserver, @unchecked Sendable {
    @MainActor var eventHandler: ((SystemContentSelectionEvent) -> Void)?

    private let picker: SCContentSharingPicker
    private var observing = false

    override init() {
        picker = .shared
        super.init()
    }

    @MainActor
    func present() {
        activateIfNeeded()

        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleApplication, .singleWindow]
        configuration.allowsChangingSelectedContent = true
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleIdentifier]
        }
        picker.configuration = configuration
        picker.maximumStreamCount = 1
        picker.present()
    }

    @MainActor
    func deactivate() {
        picker.isActive = false
        if observing {
            picker.remove(self)
            observing = false
        }
    }

    @MainActor
    private func activateIfNeeded() {
        if !observing {
            picker.add(self)
            observing = true
        }
        picker.isActive = true
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let event = SystemContentSelectionEvent.selected(
            SystemContentSelection(filter: filter),
            isUpdate: stream != nil
        )
        Task { @MainActor [weak self] in
            self?.eventHandler?(event)
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        let event = SystemContentSelectionEvent.cancelled(isUpdate: stream != nil)
        Task { @MainActor [weak self] in
            self?.eventHandler?(event)
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.eventHandler?(.failed(message))
        }
    }
}
