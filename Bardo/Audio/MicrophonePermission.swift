import AppKit
import AVFoundation
import Foundation

enum MicrophonePermissionState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case error(String)
}

@MainActor
protocol MicrophonePermissionAuthorizing: AnyObject {
    func currentStatus() -> MicrophonePermissionState
    func requestAccess() async -> MicrophonePermissionState
}

@MainActor
final class SystemMicrophonePermissionAuthorizer: MicrophonePermissionAuthorizing {
    func currentStatus() -> MicrophonePermissionState {
        Self.state(for: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    func requestAccess() async -> MicrophonePermissionState {
        let current = currentStatus()
        guard current == .notDetermined else {
            return current
        }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if granted {
            return .authorized
        }

        let resolved = currentStatus()
        return resolved == .notDetermined ? .denied : resolved
    }

    static func state(for status: AVAuthorizationStatus) -> MicrophonePermissionState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .error("macOS returned an unknown microphone authorization state.")
        }
    }
}

@MainActor
struct MicrophoneSystemSettingsOpener {
    func open() -> Bool {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        ) else {
            return false
        }

        return NSWorkspace.shared.open(url)
    }
}
