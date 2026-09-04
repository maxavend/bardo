import Darwin
import Dispatch
import Foundation

enum WhisperThermalLevel: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }

    var severity: Int {
        switch self {
        case .unknown: return -1
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    static func worse(_ lhs: WhisperThermalLevel, _ rhs: WhisperThermalLevel) -> WhisperThermalLevel {
        lhs.severity >= rhs.severity ? lhs : rhs
    }
}

struct WhisperRuntimeSample: Codable, Equatable, Sendable {
    let elapsedWallSeconds: TimeInterval
    let processedAudioSeconds: TimeInterval
    let residentMemoryBytes: UInt64
    let thermalState: WhisperThermalLevel
}

struct WhisperRuntimeProbeSnapshot: Equatable, Sendable {
    let timeToFirstTextSeconds: TimeInterval?
    let peakResidentMemoryBytes: UInt64?
    let memoryPressureOccurred: Bool
    let thermalStateAtStart: WhisperThermalLevel
    let worstThermalState: WhisperThermalLevel
    let thermalStateAtEnd: WhisperThermalLevel
    let progressSamples: [WhisperRuntimeSample]
}

final class WhisperRuntimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.maxavend.bardo.whisper-runtime-probe",
        qos: .utility
    )
    private let startedAt = ProcessInfo.processInfo.systemUptime

    private var firstTextAt: TimeInterval?
    private var peakResidentMemoryBytes: UInt64 = 0
    private var memoryPressureOccurred = false
    private var thermalStateAtStart = WhisperThermalLevel(ProcessInfo.processInfo.thermalState)
    private var worstThermalState = WhisperThermalLevel(ProcessInfo.processInfo.thermalState)
    private var progressSamples: [WhisperRuntimeSample] = []

    private var timer: DispatchSourceTimer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    func start() {
        sampleCurrentState()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(250),
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            self?.sampleCurrentState()
        }

        let memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        memoryPressureSource.setEventHandler { [weak self] in
            self?.markMemoryPressure()
        }

        lock.lock()
        self.timer = timer
        self.memoryPressureSource = memoryPressureSource
        lock.unlock()

        timer.resume()
        memoryPressureSource.resume()
    }

    func markFirstText() {
        lock.lock()
        if firstTextAt == nil {
            firstTextAt = ProcessInfo.processInfo.systemUptime
        }
        lock.unlock()
    }

    func markProgress(processedAudioSeconds: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        let memory = Self.currentResidentMemoryBytes()
        let thermal = WhisperThermalLevel(ProcessInfo.processInfo.thermalState)

        lock.lock()
        peakResidentMemoryBytes = max(peakResidentMemoryBytes, memory)
        worstThermalState = WhisperThermalLevel.worse(worstThermalState, thermal)
        progressSamples.append(
            WhisperRuntimeSample(
                elapsedWallSeconds: max(0, now - startedAt),
                processedAudioSeconds: max(0, processedAudioSeconds),
                residentMemoryBytes: memory,
                thermalState: thermal
            )
        )
        lock.unlock()
    }

    func stop() -> WhisperRuntimeProbeSnapshot {
        sampleCurrentState()

        lock.lock()
        let timer = self.timer
        let memoryPressureSource = self.memoryPressureSource
        self.timer = nil
        self.memoryPressureSource = nil

        let endThermal = WhisperThermalLevel(ProcessInfo.processInfo.thermalState)
        let snapshot = WhisperRuntimeProbeSnapshot(
            timeToFirstTextSeconds: firstTextAt.map { max(0, $0 - startedAt) },
            peakResidentMemoryBytes: peakResidentMemoryBytes > 0 ? peakResidentMemoryBytes : nil,
            memoryPressureOccurred: memoryPressureOccurred,
            thermalStateAtStart: thermalStateAtStart,
            worstThermalState: WhisperThermalLevel.worse(worstThermalState, endThermal),
            thermalStateAtEnd: endThermal,
            progressSamples: progressSamples
        )
        lock.unlock()

        timer?.cancel()
        memoryPressureSource?.cancel()
        return snapshot
    }

    private func sampleCurrentState() {
        let memory = Self.currentResidentMemoryBytes()
        let thermal = WhisperThermalLevel(ProcessInfo.processInfo.thermalState)

        lock.lock()
        peakResidentMemoryBytes = max(peakResidentMemoryBytes, memory)
        worstThermalState = WhisperThermalLevel.worse(worstThermalState, thermal)
        lock.unlock()
    }

    private func markMemoryPressure() {
        lock.lock()
        memoryPressureOccurred = true
        lock.unlock()
    }

    private static func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}
