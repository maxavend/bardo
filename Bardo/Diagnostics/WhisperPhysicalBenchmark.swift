import Foundation
import OSLog

enum WhisperBenchmarkError: Error, LocalizedError {
    case missingAudioPath
    case missingWorkerForChunkMatrix
    case invalidLongProfiles
    case invalidConfiguration(String)
    case missingMetrics

    var errorDescription: String? {
        switch self {
        case .missingAudioPath:
            return "Set BARDO_WHISPER_BENCHMARK_AUDIO to an absolute local audio path."
        case .missingWorkerForChunkMatrix:
            return "The chunks matrix requires BARDO_WHISPER_BENCHMARK_WORKER with the winning worker count."
        case .invalidLongProfiles:
            return "BARDO_WHISPER_BENCHMARK_LONG_PROFILES must look like 120:2:6,120:2:8."
        case .invalidConfiguration(let message):
            return message
        case .missingMetrics:
            return "Whisper completed without publishing benchmark metrics."
        }
    }
}

struct WhisperBenchmarkProfileDescriptor: Codable, Equatable, Sendable {
    let id: String
    let incrementalChunkDurationSeconds: Double
    let maxBufferedChunks: Int
    let concurrentWorkerCount: Int
    let usesVAD: Bool
    let temperatureFallbackCount: Int

    init(
        id: String? = nil,
        chunk: Double,
        bufferedChunks: Int,
        workers: Int,
        usesVAD: Bool = true,
        fallbacks: Int = 5
    ) {
        self.incrementalChunkDurationSeconds = chunk
        self.maxBufferedChunks = bufferedChunks
        self.concurrentWorkerCount = workers
        self.usesVAD = usesVAD
        self.temperatureFallbackCount = fallbacks
        self.id = id ?? "chunk-\(Int(chunk))-buffer-\(bufferedChunks)-workers-\(workers)"
    }

    func runtimeProfile(physicalMemory: UInt64) -> WhisperPerformanceProfile {
        WhisperPerformanceProfile(
            physicalMemory: physicalMemory,
            incrementalChunkDurationSeconds: incrementalChunkDurationSeconds,
            maxBufferedChunks: maxBufferedChunks,
            concurrentWorkerCount: concurrentWorkerCount,
            usesVAD: usesVAD,
            temperatureFallbackCount: temperatureFallbackCount
        )
    }
}

struct WhisperBenchmarkConfiguration: Sendable {
    enum Matrix: String, Sendable {
        case workers
        case chunks
        case long
        case single
    }

    static let audioKey = "BARDO_WHISPER_BENCHMARK_AUDIO"
    static let referenceKey = "BARDO_WHISPER_BENCHMARK_REFERENCE"
    static let outputKey = "BARDO_WHISPER_BENCHMARK_OUTPUT"
    static let matrixKey = "BARDO_WHISPER_BENCHMARK_MATRIX"
    static let repetitionsKey = "BARDO_WHISPER_BENCHMARK_REPETITIONS"
    static let workerKey = "BARDO_WHISPER_BENCHMARK_WORKER"
    static let longProfilesKey = "BARDO_WHISPER_BENCHMARK_LONG_PROFILES"
    static let cooldownKey = "BARDO_WHISPER_BENCHMARK_COOLDOWN_SECONDS"
    static let gitSHAKey = "BARDO_WHISPER_BENCHMARK_GIT_SHA"

    let audioURL: URL
    let referenceURL: URL?
    let outputDirectory: URL
    let matrix: Matrix
    let repetitions: Int
    let cooldownSeconds: Double
    let profiles: [WhisperBenchmarkProfileDescriptor]
    let gitSHA: String?

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment[audioKey]?.isEmpty == false
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> WhisperBenchmarkConfiguration {
        guard let audioPath = environment[audioKey], !audioPath.isEmpty else {
            throw WhisperBenchmarkError.missingAudioPath
        }

        let audioURL = URL(fileURLWithPath: (audioPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw WhisperBenchmarkError.invalidConfiguration(
                "Benchmark audio does not exist at \(audioURL.path)."
            )
        }

        let referenceURL = environment[referenceKey]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        if let referenceURL,
           !FileManager.default.fileExists(atPath: referenceURL.path) {
            throw WhisperBenchmarkError.invalidConfiguration(
                "Reference transcript does not exist at \(referenceURL.path)."
            )
        }

        let outputDirectory: URL
        if let outputPath = environment[outputKey], !outputPath.isEmpty {
            outputDirectory = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            outputDirectory = home
                .appendingPathComponent("Desktop", isDirectory: true)
                .appendingPathComponent("BardoWhisperBenchmarks", isDirectory: true)
        }

        let matrix = Matrix(rawValue: environment[matrixKey] ?? "") ?? .workers
        let defaultRepetitions = matrix == .long ? 1 : 3
        let repetitions = min(
            10,
            max(1, environment[repetitionsKey].flatMap(Int.init) ?? defaultRepetitions)
        )
        let cooldownSeconds = min(
            300,
            max(0, environment[cooldownKey].flatMap(Double.init) ?? 5)
        )

        let profiles: [WhisperBenchmarkProfileDescriptor]
        switch matrix {
        case .workers:
            profiles = [4, 6, 8].map {
                WhisperBenchmarkProfileDescriptor(chunk: 120, bufferedChunks: 2, workers: $0)
            }
        case .chunks:
            guard let worker = environment[workerKey].flatMap(Int.init), (1...16).contains(worker) else {
                throw WhisperBenchmarkError.missingWorkerForChunkMatrix
            }
            profiles = [
                (90.0, 1), (90.0, 2),
                (120.0, 1), (120.0, 2),
                (150.0, 1), (150.0, 2)
            ].map {
                WhisperBenchmarkProfileDescriptor(
                    chunk: $0.0,
                    bufferedChunks: $0.1,
                    workers: worker
                )
            }
        case .long:
            guard let raw = environment[longProfilesKey], !raw.isEmpty else {
                throw WhisperBenchmarkError.invalidLongProfiles
            }
            profiles = try parseProfiles(raw)
        case .single:
            let base = WhisperPerformanceProfile(environment: environment)
            profiles = [
                WhisperBenchmarkProfileDescriptor(
                    chunk: base.incrementalChunkDurationSeconds,
                    bufferedChunks: base.maxBufferedChunks,
                    workers: base.concurrentWorkerCount,
                    usesVAD: base.usesVAD,
                    fallbacks: base.temperatureFallbackCount
                )
            ]
        }

        return WhisperBenchmarkConfiguration(
            audioURL: audioURL,
            referenceURL: referenceURL,
            outputDirectory: outputDirectory,
            matrix: matrix,
            repetitions: repetitions,
            cooldownSeconds: cooldownSeconds,
            profiles: profiles,
            gitSHA: environment[gitSHAKey]
        )
    }

    private static func parseProfiles(_ raw: String) throws -> [WhisperBenchmarkProfileDescriptor] {
        let entries = raw.split(separator: ",")
        let profiles = entries.compactMap { entry -> WhisperBenchmarkProfileDescriptor? in
            let pieces = entry.split(separator: ":")
            guard pieces.count == 3,
                  let chunk = Double(pieces[0]),
                  let bufferedChunks = Int(pieces[1]),
                  let workers = Int(pieces[2]),
                  (30...600).contains(chunk),
                  (1...8).contains(bufferedChunks),
                  (1...16).contains(workers) else {
                return nil
            }
            return WhisperBenchmarkProfileDescriptor(
                chunk: chunk,
                bufferedChunks: bufferedChunks,
                workers: workers
            )
        }

        guard !profiles.isEmpty, profiles.count == entries.count else {
            throw WhisperBenchmarkError.invalidLongProfiles
        }
        return profiles
    }
}

struct WhisperBenchmarkHardware: Codable, Sendable {
    let macModel: String
    let chipName: String
    let physicalMemoryBytes: UInt64
    let osVersion: String
    let processorCount: Int
    let activeProcessorCount: Int
    let gitSHA: String?
}

struct WhisperBenchmarkQuality: Codable, Sendable {
    let languageCode: String?
    let wordTimestampCoverage: Double
    let referenceProvided: Bool
    let wordErrorRate: Double?
    let characterErrorRate: Double?
}

struct WhisperBenchmarkRunMetrics: Codable, Sendable {
    let audioSeconds: TimeInterval
    let modelPreparationSeconds: TimeInterval
    let modelLoadSeconds: TimeInterval
    let inferenceSeconds: TimeInterval
    let endToEndSeconds: TimeInterval
    let timeToFirstTextSeconds: TimeInterval?
    let asrRealTimeFactor: Double
    let endToEndRealTimeFactor: Double
    let segmentCount: Int
    let wordCount: Int
    let fallbackCount: Int
    let vadWindowCount: Int
    let peakResidentMemoryBytes: UInt64?
    let memoryPressureOccurred: Bool
    let thermalStateAtStart: WhisperThermalLevel
    let worstThermalState: WhisperThermalLevel
    let thermalStateAtEnd: WhisperThermalLevel
    let progressSamples: [WhisperRuntimeSample]

    init(_ metrics: WhisperTranscriptionMetrics) {
        audioSeconds = metrics.audioSeconds
        modelPreparationSeconds = metrics.modelPreparationSeconds
        modelLoadSeconds = metrics.modelLoadSeconds
        inferenceSeconds = metrics.inferenceSeconds
        endToEndSeconds = metrics.endToEndSeconds
        timeToFirstTextSeconds = metrics.timeToFirstTextSeconds
        asrRealTimeFactor = metrics.asrRealTimeFactor
        endToEndRealTimeFactor = metrics.endToEndRealTimeFactor
        segmentCount = metrics.segmentCount
        wordCount = metrics.wordCount
        fallbackCount = metrics.fallbackCount
        vadWindowCount = metrics.vadWindowCount
        peakResidentMemoryBytes = metrics.peakResidentMemoryBytes
        memoryPressureOccurred = metrics.memoryPressureOccurred
        thermalStateAtStart = metrics.thermalStateAtStart
        worstThermalState = metrics.worstThermalState
        thermalStateAtEnd = metrics.thermalStateAtEnd
        progressSamples = metrics.progressSamples
    }
}

struct WhisperBenchmarkRunResult: Codable, Sendable {
    let profile: WhisperBenchmarkProfileDescriptor
    let runIndex: Int
    let runKind: String
    let startedAt: Date
    let metrics: WhisperBenchmarkRunMetrics
    let quality: WhisperBenchmarkQuality
}

struct WhisperBenchmarkProfileSummary: Codable, Sendable {
    let profile: WhisperBenchmarkProfileDescriptor
    let runCount: Int
    let medianASRRealTimeFactor: Double
    let standardDeviationASRRealTimeFactor: Double
    let minASRRealTimeFactor: Double
    let maxASRRealTimeFactor: Double
    let medianEndToEndRealTimeFactor: Double
    let medianTimeToFirstTextSeconds: Double?
    let peakResidentMemoryBytes: UInt64?
    let memoryPressureOccurred: Bool
    let worstThermalState: WhisperThermalLevel
    let medianWordErrorRate: Double?
    let medianCharacterErrorRate: Double?
}

struct WhisperBenchmarkReport: Codable, Sendable {
    let schemaVersion: Int
    let startedAt: Date
    var completedAt: Date?
    let audioFileName: String
    let referenceProvided: Bool
    let matrix: String
    let repetitions: Int
    let bootstrapSeconds: TimeInterval
    let hardware: WhisperBenchmarkHardware
    var runs: [WhisperBenchmarkRunResult]
    var summaries: [WhisperBenchmarkProfileSummary]
}

enum WhisperPhysicalBenchmarkRunner {
    private static let logger = Logger(
        subsystem: "com.maxavend.bardo",
        category: "whisper.benchmark"
    )

    static func runFromEnvironment() async -> Int32 {
        do {
            let configuration = try WhisperBenchmarkConfiguration.fromEnvironment()
            try await run(configuration)
            return 0
        } catch {
            writeToStandardError("Bardo Whisper benchmark failed: \(error.localizedDescription)\n")
            return 2
        }
    }

    static func run(_ configuration: WhisperBenchmarkConfiguration) async throws {
        try FileManager.default.createDirectory(
            at: configuration.outputDirectory,
            withIntermediateDirectories: true
        )

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoWhisperBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = RecordingStore(rootURL: temporaryRoot)
        let importer = AudioImportService(store: store)
        let recording = try await importer.importFile(at: configuration.audioURL)
        let referenceText = try configuration.referenceURL.map {
            try String(contentsOf: $0, encoding: .utf8)
        }

        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let hardware = WhisperBenchmarkHardware(
            macModel: sysctlValue("hw.model") ?? "unknown",
            chipName: sysctlValue("machdep.cpu.brand_string") ?? "unknown",
            physicalMemoryBytes: physicalMemory,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            gitSHA: configuration.gitSHA
        )

        writeToStandardOutput(
            "Preparing Whisper once before timed profiles. This removes model download/Core ML specialization from profile comparisons.\n"
        )
        let bootstrapStartedAt = ProcessInfo.processInfo.systemUptime
        let bootstrapManager = try TranscriptionModelManager.live()
        let bootstrapService = WhisperTranscriptionService(
            modelManager: bootstrapManager,
            performanceProfile: configuration.profiles[0].runtimeProfile(physicalMemory: physicalMemory)
        )
        try await bootstrapService.prepareForUse { snapshot in
            let percent = Int((snapshot.fractionCompleted * 100).rounded())
            Self.logger.info(
                "Benchmark bootstrap stage=\(snapshot.stage.rawValue, privacy: .public) progress=\(percent)"
            )
        }
        await bootstrapService.unloadForDiagnostics()
        let bootstrapSeconds = max(
            0,
            ProcessInfo.processInfo.systemUptime - bootstrapStartedAt
        )

        var report = WhisperBenchmarkReport(
            schemaVersion: 1,
            startedAt: Date(),
            completedAt: nil,
            audioFileName: configuration.audioURL.lastPathComponent,
            referenceProvided: referenceText != nil,
            matrix: configuration.matrix.rawValue,
            repetitions: configuration.repetitions,
            bootstrapSeconds: bootstrapSeconds,
            hardware: hardware,
            runs: [],
            summaries: []
        )
        try write(report, to: configuration.outputDirectory)

        for (profileIndex, descriptor) in configuration.profiles.enumerated() {
            if profileIndex > 0 {
                await coolDown(
                    fixedSeconds: configuration.cooldownSeconds,
                    thermalRecoveryLimitSeconds: 120
                )
            }

            writeToStandardOutput(
                "\nProfile \(profileIndex + 1)/\(configuration.profiles.count): \(descriptor.id)\n"
            )

            let manager = try TranscriptionModelManager.live()
            let service = WhisperTranscriptionService(
                modelManager: manager,
                performanceProfile: descriptor.runtimeProfile(physicalMemory: physicalMemory)
            )

            for runIndex in 0..<configuration.repetitions {
                let runKind = runIndex == 0 ? "cold-model-load" : "warm"
                writeToStandardOutput(
                    "  Run \(runIndex + 1)/\(configuration.repetitions) [\(runKind)]..."
                )

                let runStartedAt = Date()
                let transcript = try await service.transcribe(
                    recording: recording,
                    store: store,
                    progress: { _ in },
                    liveUpdate: { _ in }
                )
                guard let metrics = await service.lastMetrics else {
                    throw WhisperBenchmarkError.missingMetrics
                }

                let quality = makeQuality(transcript: transcript, referenceText: referenceText)
                let result = WhisperBenchmarkRunResult(
                    profile: descriptor,
                    runIndex: runIndex + 1,
                    runKind: runKind,
                    startedAt: runStartedAt,
                    metrics: WhisperBenchmarkRunMetrics(metrics),
                    quality: quality
                )
                report.runs.append(result)
                report.summaries = makeSummaries(from: report.runs)
                try write(report, to: configuration.outputDirectory)

                let memoryMB = Double(metrics.peakResidentMemoryBytes ?? 0) / 1_048_576
                writeToStandardOutput(
                    String(
                        format: " RTF %.4f | E2E %.4f | TTFT %.2fs | peak %.0f MB | thermal %@\n",
                        metrics.asrRealTimeFactor,
                        metrics.endToEndRealTimeFactor,
                        metrics.timeToFirstTextSeconds ?? -1,
                        memoryMB,
                        metrics.worstThermalState.rawValue
                    )
                )
            }

            await service.unloadForDiagnostics()
        }

        report.completedAt = Date()
        report.summaries = makeSummaries(from: report.runs)
        try write(report, to: configuration.outputDirectory)

        writeToStandardOutput(
            "\nBenchmark complete. Results: \(configuration.outputDirectory.path)\n"
        )
    }

    private static func makeQuality(
        transcript: Transcript,
        referenceText: String?
    ) -> WhisperBenchmarkQuality {
        let words = transcript.segments.flatMap(\.words)
        let timestampedWords = words.filter {
            $0.startTime.isFinite
                && $0.endTime.isFinite
                && $0.startTime >= 0
                && $0.endTime >= $0.startTime
        }
        let timestampCoverage = words.isEmpty
            ? 0
            : Double(timestampedWords.count) / Double(words.count)

        guard let referenceText else {
            return WhisperBenchmarkQuality(
                languageCode: transcript.languageCode,
                wordTimestampCoverage: timestampCoverage,
                referenceProvided: false,
                wordErrorRate: nil,
                characterErrorRate: nil
            )
        }

        return WhisperBenchmarkQuality(
            languageCode: transcript.languageCode,
            wordTimestampCoverage: timestampCoverage,
            referenceProvided: true,
            wordErrorRate: errorRate(
                reference: normalizedWords(referenceText),
                hypothesis: normalizedWords(transcript.text)
            ),
            characterErrorRate: errorRate(
                reference: Array(normalizedCharacters(referenceText)),
                hypothesis: Array(normalizedCharacters(transcript.text))
            )
        )
    }

    private static func normalizedWords(_ text: String) -> [String] {
        normalizedCharacters(text)
            .split(whereSeparator: \.isWhitespace)
            .map { String($0) }
    }

    private static func normalizedCharacters(_ text: String) -> String {
        let lowered = text.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return Character(String(scalar))
            }
            return " "
        }
        return String(mapped)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func errorRate<T: Equatable>(
        reference: [T],
        hypothesis: [T]
    ) -> Double {
        guard !reference.isEmpty else {
            return hypothesis.isEmpty ? 0 : 1
        }
        return Double(editDistance(reference, hypothesis)) / Double(reference.count)
    }

    private static func editDistance<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        for (row, left) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = row + 1
            for (column, right) in rhs.enumerated() {
                let substitution = previous[column] + (left == right ? 0 : 1)
                let insertion = current[column] + 1
                let deletion = previous[column + 1] + 1
                current[column + 1] = min(substitution, insertion, deletion)
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func makeSummaries(
        from runs: [WhisperBenchmarkRunResult]
    ) -> [WhisperBenchmarkProfileSummary] {
        let grouped = Dictionary(grouping: runs, by: \.profile.id)
        return grouped.values.compactMap { profileRuns in
            guard let profile = profileRuns.first?.profile else { return nil }
            let asr = profileRuns.map { $0.metrics.asrRealTimeFactor }
            let e2e = profileRuns.map { $0.metrics.endToEndRealTimeFactor }
            let ttft = profileRuns.compactMap { $0.metrics.timeToFirstTextSeconds }
            let peaks = profileRuns.compactMap { $0.metrics.peakResidentMemoryBytes }
            let wers = profileRuns.compactMap { $0.quality.wordErrorRate }
            let cers = profileRuns.compactMap { $0.quality.characterErrorRate }
            let worst = profileRuns
                .map { $0.metrics.worstThermalState }
                .reduce(.unknown, WhisperThermalLevel.worse)

            return WhisperBenchmarkProfileSummary(
                profile: profile,
                runCount: profileRuns.count,
                medianASRRealTimeFactor: median(asr) ?? 0,
                standardDeviationASRRealTimeFactor: standardDeviation(asr),
                minASRRealTimeFactor: asr.min() ?? 0,
                maxASRRealTimeFactor: asr.max() ?? 0,
                medianEndToEndRealTimeFactor: median(e2e) ?? 0,
                medianTimeToFirstTextSeconds: median(ttft),
                peakResidentMemoryBytes: peaks.max(),
                memoryPressureOccurred: profileRuns.contains { $0.metrics.memoryPressureOccurred },
                worstThermalState: worst,
                medianWordErrorRate: median(wers),
                medianCharacterErrorRate: median(cers)
            )
        }.sorted {
            $0.medianASRRealTimeFactor < $1.medianASRRealTimeFactor
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { partial, value in
            partial + pow(value - mean, 2)
        } / Double(values.count - 1)
        return sqrt(variance)
    }

    private static func coolDown(
        fixedSeconds: Double,
        thermalRecoveryLimitSeconds: Double
    ) async {
        if fixedSeconds > 0 {
            try? await Task.sleep(
                nanoseconds: UInt64(fixedSeconds * 1_000_000_000)
            )
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.thermalState == .serious
                || ProcessInfo.processInfo.thermalState == .critical {
            guard ProcessInfo.processInfo.systemUptime - startedAt < thermalRecoveryLimitSeconds else {
                writeToStandardOutput(
                    "Thermal recovery limit reached; continuing and preserving the thermal state in results.\n"
                )
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private static func write(
        _ report: WhisperBenchmarkReport,
        to directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let json = try encoder.encode(report)
        try json.write(
            to: directory.appendingPathComponent("benchmark.json"),
            options: .atomic
        )

        let runsCSV = makeRunsCSV(report.runs)
        try runsCSV.write(
            to: directory.appendingPathComponent("benchmark-runs.csv"),
            atomically: true,
            encoding: .utf8
        )

        let summaryCSV = makeSummaryCSV(report.summaries)
        try summaryCSV.write(
            to: directory.appendingPathComponent("benchmark-summary.csv"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func makeRunsCSV(_ runs: [WhisperBenchmarkRunResult]) -> String {
        var lines = [
            "profile,run,kind,chunk_seconds,buffers,workers,audio_seconds,model_prepare_seconds,model_load_seconds,inference_seconds,e2e_seconds,ttft_seconds,asr_rtf,e2e_rtf,peak_resident_bytes,memory_pressure,thermal_start,thermal_worst,thermal_end,segments,words,fallbacks,vad_windows,language,timestamp_coverage,wer,cer"
        ]

        for run in runs {
            let values: [String] = [
                run.profile.id,
                String(run.runIndex),
                run.runKind,
                String(run.profile.incrementalChunkDurationSeconds),
                String(run.profile.maxBufferedChunks),
                String(run.profile.concurrentWorkerCount),
                String(run.metrics.audioSeconds),
                String(run.metrics.modelPreparationSeconds),
                String(run.metrics.modelLoadSeconds),
                String(run.metrics.inferenceSeconds),
                String(run.metrics.endToEndSeconds),
                run.metrics.timeToFirstTextSeconds.map { String($0) } ?? "",
                String(run.metrics.asrRealTimeFactor),
                String(run.metrics.endToEndRealTimeFactor),
                run.metrics.peakResidentMemoryBytes.map { String($0) } ?? "",
                String(run.metrics.memoryPressureOccurred),
                run.metrics.thermalStateAtStart.rawValue,
                run.metrics.worstThermalState.rawValue,
                run.metrics.thermalStateAtEnd.rawValue,
                String(run.metrics.segmentCount),
                String(run.metrics.wordCount),
                String(run.metrics.fallbackCount),
                String(run.metrics.vadWindowCount),
                run.quality.languageCode ?? "",
                String(run.quality.wordTimestampCoverage),
                run.quality.wordErrorRate.map { String($0) } ?? "",
                run.quality.characterErrorRate.map { String($0) } ?? ""
            ]
            lines.append(values.map(csvEscape).joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func makeSummaryCSV(
        _ summaries: [WhisperBenchmarkProfileSummary]
    ) -> String {
        var lines = [
            "profile,runs,chunk_seconds,buffers,workers,median_asr_rtf,sd_asr_rtf,min_asr_rtf,max_asr_rtf,median_e2e_rtf,median_ttft_seconds,peak_resident_bytes,memory_pressure,worst_thermal,median_wer,median_cer"
        ]

        for summary in summaries {
            let values: [String] = [
                summary.profile.id,
                String(summary.runCount),
                String(summary.profile.incrementalChunkDurationSeconds),
                String(summary.profile.maxBufferedChunks),
                String(summary.profile.concurrentWorkerCount),
                String(summary.medianASRRealTimeFactor),
                String(summary.standardDeviationASRRealTimeFactor),
                String(summary.minASRRealTimeFactor),
                String(summary.maxASRRealTimeFactor),
                String(summary.medianEndToEndRealTimeFactor),
                summary.medianTimeToFirstTextSeconds.map { String($0) } ?? "",
                summary.peakResidentMemoryBytes.map { String($0) } ?? "",
                String(summary.memoryPressureOccurred),
                summary.worstThermalState.rawValue,
                summary.medianWordErrorRate.map { String($0) } ?? "",
                summary.medianCharacterErrorRate.map { String($0) } ?? ""
            ]
            lines.append(values.map(csvEscape).joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func sysctlValue(_ key: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", key]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func writeToStandardOutput(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }

    private static func writeToStandardError(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
