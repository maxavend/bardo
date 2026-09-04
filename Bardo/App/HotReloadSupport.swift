import SwiftUI
import Combine

#if DEBUG
import Darwin

@MainActor
public final class InjectionObserver: ObservableObject {
    public static let shared = InjectionObserver()

    @Published public var injectionNumber = 0
    private var cancellable: AnyCancellable?

    private init() {
        cancellable = NotificationCenter.default.publisher(
            for: Notification.Name("INJECTION_BUNDLE_NOTIFICATION")
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.injectionNumber += 1
        }
        loadInjectionBundleIfNeeded()
    }

    public func loadInjectionBundleIfNeeded() {
        let candidatePaths = [
            "/Applications/InjectionNext.app/Contents/Resources/macOSInjection.bundle",
            "/Applications/InjectionNext.app/Contents/Resources/macOSInjection10.bundle",
            "/Applications/InjectionNext.app/Contents/Resources/macOSInjection14.bundle",
            "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle",
            "/Applications/InjectionIII.app/Contents/Resources/macOSInjection10.bundle",
            "/Applications/InjectionIII.app/Contents/Resources/macOSInjection14.bundle",
            "\(NSHomeDirectory())/Applications/InjectionNext.app/Contents/Resources/macOSInjection.bundle",
            "\(NSHomeDirectory())/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle"
        ]

        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                if let bundle = Bundle(path: path), bundle.load() {
                    print("💉 [HotReload] Loaded Injection bundle via NSBundle: \(path)")
                    return
                } else if dlopen(path + "/macOSInjection", RTLD_NOW) != nil {
                    print("💉 [HotReload] Loaded Injection bundle via dlopen: \(path)")
                    return
                }
            }
        }
    }
}

@propertyWrapper
public struct ObserveInjection: DynamicProperty {
    @ObservedObject private var observer: InjectionObserver

    public init() {
        _observer = ObservedObject(wrappedValue: MainActor.assumeIsolated {
            InjectionObserver.shared
        })
    }

    @MainActor
    public var wrappedValue: Int {
        observer.injectionNumber
    }
}

extension View {
    @inlinable
    public func enableInjection() -> some View {
        self
    }
}
#else
@propertyWrapper
public struct ObserveInjection {
    public init() {}
    public var wrappedValue: Int { 0 }
}

extension View {
    @inlinable
    public func enableInjection() -> some View {
        self
    }
}
#endif
