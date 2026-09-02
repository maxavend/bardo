import Foundation

enum ModelSettingsAction: Equatable, Sendable {
    case install
    case cancel
    case retry
    case reset
    case resetAndInstall
    case reveal
    case unavailable
}

enum ModelSettingsActionPolicy {
    static func action(
        for state: ManagedModelState,
        supportsInstallation: Bool
    ) -> ModelSettingsAction {
        switch state {
        case .notInstalled:
            return supportsInstallation ? .install : .unavailable
        case .downloading, .preparing:
            return .cancel
        case .installed:
            return .reset
        case .failed:
            return supportsInstallation ? .retry : .unavailable
        }
    }
}
