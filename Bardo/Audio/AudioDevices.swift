import AVFoundation
import Combine
import CoreAudio
import Foundation
import OSLog

/// How an audio device is connected, as Core Audio reports it.
enum AudioDeviceTransport: Equatable, Sendable {
    case builtIn
    case bluetooth
    case usb
    case airPlay
    case display
    case iPhone
    case virtual
    case other

    init(coreAudioValue value: UInt32) {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: self = .display
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: self = .iPhone
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .virtual
        default: self = .other
        }
    }

    /// A short tag for device menus. Built-in devices already say so in their name.
    var label: String? {
        switch self {
        case .builtIn, .other: nil
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .airPlay: "AirPlay"
        case .display: "Pantalla"
        case .iPhone: "iPhone"
        case .virtual: "Virtual"
        }
    }
}

struct AudioDevice: Identifiable, Hashable, Sendable {
    /// The Core Audio device UID. For an input it is also `AVCaptureDevice.uniqueID`.
    let uid: String
    let name: String
    let transport: AudioDeviceTransport

    var id: String { uid }

    var menuTitle: String {
        transport.label.map { "\(name) (\($0))" } ?? name
    }

    /// Whether this device and `other` are the two halves of one piece of hardware, such
    /// as a Bluetooth speaker's microphone and its speaker.
    func isSameHardware(as other: AudioDevice) -> Bool {
        if uid == other.uid { return true }
        guard transport == other.transport, transport == .bluetooth else { return false }
        return Self.hardwareKey(uid) == Self.hardwareKey(other.uid) || name == other.name
    }

    /// Bluetooth UIDs carry the device address followed by a role such as `:input`.
    private static func hardwareKey(_ uid: String) -> Substring {
        uid.split(separator: ":").first ?? Substring(uid)
    }
}

enum AudioDeviceDirection: Sendable {
    case input
    case output

    fileprivate var scope: AudioObjectPropertyScope {
        self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    fileprivate var defaultDeviceSelector: AudioObjectPropertySelector {
        self == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }
}

/// The microphone and output a recording uses. `nil` follows the macOS default.
struct AudioDevicePreferences: Sendable {
    private static let inputKey = "bardo.audio.input-device-uid"
    private static let inputNameKey = "bardo.audio.input-device-name"
    private static let outputKey = "bardo.audio.output-device-uid"
    private static let outputNameKey = "bardo.audio.output-device-name"

    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var inputDeviceUID: String? { defaults.string(forKey: Self.inputKey) }
    var outputDeviceUID: String? { defaults.string(forKey: Self.outputKey) }
    /// The last name seen for a chosen device, to show it while it is disconnected.
    var inputDeviceName: String? { defaults.string(forKey: Self.inputNameKey) }
    var outputDeviceName: String? { defaults.string(forKey: Self.outputNameKey) }

    func setDevice(_ device: AudioDevice?, for direction: AudioDeviceDirection) {
        let keys = direction == .input ? (Self.inputKey, Self.inputNameKey) : (Self.outputKey, Self.outputNameKey)
        if let device {
            defaults.set(device.uid, forKey: keys.0)
            defaults.set(device.name, forKey: keys.1)
        } else {
            defaults.removeObject(forKey: keys.0)
            defaults.removeObject(forKey: keys.1)
        }
    }

    /// The chosen device when it is connected; otherwise `nil`, which means the default.
    static func resolve(preferredUID: String?, among devices: [AudioDevice]) -> AudioDevice? {
        guard let preferredUID else { return nil }
        return devices.first { $0.uid == preferredUID }
    }

    /// The capture device for the chosen microphone, or the macOS default when it is gone.
    func microphoneCaptureDevice() -> AVCaptureDevice? {
        if let uid = inputDeviceUID,
           let device = AVCaptureDevice(uniqueID: uid),
           device.hasMediaType(.audio),
           device.isConnected {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    /// The Core Audio device that clocks the system tap: the chosen output when it is
    /// connected, otherwise the macOS default output.
    func outputDeviceID() -> AudioObjectID? {
        if let uid = outputDeviceUID,
           let device = AudioHardware.deviceID(forUID: uid),
           AudioHardware.devices(.output).contains(where: { $0.uid == uid }) {
            return device
        }
        return AudioHardware.defaultDeviceID(.output)
    }
}

/// When the chosen microphone is a Bluetooth device, macOS switches it to its hands-free
/// profile: its microphone and speaker drop to telephone quality.
enum HandsFreeRisk: Equatable, Sendable {
    case microphone
    case microphoneAndOutput

    init?(input: AudioDevice?, output: AudioDevice?) {
        guard let input, input.transport == .bluetooth else { return nil }
        if let output, output.isSameHardware(as: input) {
            self = .microphoneAndOutput
        } else {
            self = .microphone
        }
    }
}

/// Plain Core Audio queries about the Mac's audio devices.
enum AudioHardware {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func devices(_ direction: AudioDeviceDirection) -> [AudioDevice] {
        allDeviceIDs().compactMap { id -> AudioDevice? in
            // Devices that cannot be a default, such as Bardo's private aggregate or
            // other apps' helper devices, are not something to choose.
            guard hasStreams(id, direction), canBeDefault(id, direction),
                  let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                  let name = string(kAudioObjectPropertyName, of: id)
            else { return nil }
            let transport: UInt32 = value(kAudioDevicePropertyTransportType, of: id) ?? 0
            return AudioDevice(uid: uid, name: name, transport: AudioDeviceTransport(coreAudioValue: transport))
        }
    }

    static func defaultDeviceID(_ direction: AudioDeviceDirection) -> AudioObjectID? {
        let id: AudioObjectID? = value(direction.defaultDeviceSelector, of: system)
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func defaultDevice(_ direction: AudioDeviceDirection) -> AudioDevice? {
        guard let id = defaultDeviceID(direction),
              let uid = string(kAudioDevicePropertyDeviceUID, of: id)
        else { return nil }
        return devices(direction).first { $0.uid == uid }
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func uid(of device: AudioObjectID) -> String? {
        string(kAudioDevicePropertyDeviceUID, of: device)
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasStreams(_ id: AudioObjectID, _ direction: AudioDeviceDirection) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: direction.scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func canBeDefault(_ id: AudioObjectID, _ direction: AudioDeviceDirection) -> Bool {
        let flag: UInt32? = value(kAudioDevicePropertyDeviceCanBeDefaultDevice, of: id, scope: direction.scope)
        return flag != 0
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func value<Value: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        of id: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Value? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Value>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<Value>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr,
              size == UInt32(MemoryLayout<Value>.size)
        else { return nil }
        return pointer.load(as: Value.self)
    }
}

/// The Mac's microphones and outputs, kept current as devices connect and disconnect
/// and as the macOS defaults change.
@MainActor
final class AudioDeviceCatalog: ObservableObject {
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var defaultInput: AudioDevice?
    @Published private(set) var defaultOutput: AudioDevice?

    private static let logger = Logger(subsystem: "com.maxavend.bardo", category: "audio-devices")
    private static let watchedSelectors = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice
    ]
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        refresh()
    }

    /// Starts following device changes. Calling it again while listening does nothing.
    func startObserving() {
        guard listeners.isEmpty else { return }
        #if DEBUG
        if DesignReview.isActive { return }
        #endif
        for selector in Self.watchedSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            if status == noErr {
                listeners.append((address, block))
            } else {
                Self.logger.error("Could not follow audio device changes: \(status, privacy: .public)")
            }
        }
        refresh()
    }

    func stopObserving() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        listeners.removeAll()
    }

    func refresh() {
        #if DEBUG
        // The design review shows neutral devices instead of the reviewer's own.
        if let name = DesignReview.microphoneName {
            let microphone = AudioDevice(uid: "design-review-input", name: name, transport: .builtIn)
            let output = AudioDevice(uid: "design-review-output", name: "Altavoces del MacBook Air", transport: .builtIn)
            (inputs, outputs, defaultInput, defaultOutput) = ([microphone], [output], microphone, output)
            return
        }
        #endif
        let inputs = AudioHardware.devices(.input)
        let outputs = AudioHardware.devices(.output)
        if inputs != self.inputs { self.inputs = inputs }
        if outputs != self.outputs { self.outputs = outputs }
        let defaultInput = AudioHardware.defaultDevice(.input)
        let defaultOutput = AudioHardware.defaultDevice(.output)
        if defaultInput != self.defaultInput { self.defaultInput = defaultInput }
        if defaultOutput != self.defaultOutput { self.defaultOutput = defaultOutput }
    }
}
