import Foundation

enum MacOSUICompatibility {
    static var usesNativeToolbar: Bool {
        usesNativeToolbar(for: ProcessInfo.processInfo.operatingSystemVersion)
    }

    static func usesNativeToolbar(for version: OperatingSystemVersion) -> Bool {
        version.majorVersion < 27
    }
}
