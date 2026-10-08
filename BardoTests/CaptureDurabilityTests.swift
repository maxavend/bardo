import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import XCTest
@testable import Bardo

final class CaptureDurabilityTests: XCTestCase {
    private var baseURL: URL!

    override func setUpWithError() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BardoCaptureDurability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let baseURL { try? FileManager.default.removeItem(at: baseURL) }
        baseURL = nil
    }

    // MARK: - Fragmented realtime writer

    func testUnfinishedSystemTrackIsReadableUpToItsLastFragment() async throws {
        let url = baseURL.appendingPathComponent("system.m4a")
        let writer = CMSampleBufferAudioWriter(outputURL: url, channelCount: 2)

        for buffer in SyntheticAudio.buffers(seconds: 4, channels: 2) {
            XCTAssertEqual(writer.append(buffer), .accepted)
        }

        // Never call finish(): this is the state a crash or force quit leaves behind.
        let readableDuration = await SyntheticAudio.waitForReadableDuration(at: url, atLeast: 2)
        XCTAssertGreaterThanOrEqual(readableDuration, 2, "Fragments must make interrupted captures readable")
    }

    func testFinishedTrackHasFullDurationAndTiming() async throws {
        let url = baseURL.appendingPathComponent("finished.m4a")
        let writer = CMSampleBufferAudioWriter(outputURL: url, channelCount: 1, bitRate: 96_000)

        for buffer in SyntheticAudio.buffers(seconds: 3, channels: 1) {
            writer.append(buffer)
        }
        let timing = try await writer.finish(sourceName: "microphone")

        XCTAssertEqual(timing.lastPresentationTime - timing.firstPresentationTime, 3, accuracy: 0.05)
        XCTAssertNil(timing.warning)
        XCTAssertEqual(try AudioMetadataReader().read(from: url).duration, 3, accuracy: 0.1)
    }

    func testBurstFasterThanRealtimeIsQueuedWithoutLosingAudio() async throws {
        let url = baseURL.appendingPathComponent("burst.m4a")
        let writer = CMSampleBufferAudioWriter(outputURL: url, channelCount: 2)

        // Twenty seconds delivered at once outpace the realtime encoder; the writer must
        // absorb the backlog instead of treating it as a fatal error.
        for buffer in SyntheticAudio.buffers(seconds: 20, channels: 2) {
            if case .failed(_, let message) = writer.append(buffer) {
                return XCTFail("A burst must not fail the track: \(message)")
            }
        }
        let timing = try await writer.finish(sourceName: "system")

        XCTAssertFalse(writer.hasFailed)
        XCTAssertNil(timing.warning)
        XCTAssertEqual(timing.lastPresentationTime - timing.firstPresentationTime, 20, accuracy: 0.05)
        XCTAssertEqual(try AudioMetadataReader().read(from: url).duration, 20, accuracy: 0.1)
    }

    func testBacklogOverflowSkipsAudioButKeepsTheTrackAlive() async throws {
        let url = baseURL.appendingPathComponent("overflow.m4a")
        let writer = CMSampleBufferAudioWriter(outputURL: url, channelCount: 2, maximumPendingBuffers: 4)

        // The encoder's own buffering absorbs short bursts; thirty seconds overflow it.
        for buffer in SyntheticAudio.buffers(seconds: 30, channels: 2) {
            if case .failed(_, let message) = writer.append(buffer) {
                return XCTFail("An overflowing backlog must not fail the track: \(message)")
            }
        }
        let timing = try await writer.finish(sourceName: "system")

        XCTAssertFalse(writer.hasFailed)
        XCTAssertTrue(timing.warning?.contains("skipped") == true)
        XCTAssertGreaterThan(try AudioMetadataReader().read(from: url).duration, 0)
    }

    func testSamplesAfterFinalizationAreIgnored() async throws {
        let url = baseURL.appendingPathComponent("late.m4a")
        let writer = CMSampleBufferAudioWriter(outputURL: url, channelCount: 1)
        let buffers = SyntheticAudio.buffers(seconds: 1, channels: 1)
        buffers.dropLast().forEach { writer.append($0) }
        _ = try await writer.finish(sourceName: "microphone")

        XCTAssertEqual(writer.append(try XCTUnwrap(buffers.last)), .ignored)
    }

    func testOneFailedTrackKeepsTheOtherRecording() {
        let processor = SystemAudioSampleProcessor()
        let unwritable = baseURL
            .appendingPathComponent("missing-directory", isDirectory: true)
            .appendingPathComponent("microphone.m4a")
        processor.configure(systemURL: baseURL.appendingPathComponent("system.m4a"), microphoneURL: unwritable)

        let systemBuffers = SyntheticAudio.buffers(seconds: 0.2, channels: 2)
        let microphoneBuffers = SyntheticAudio.buffers(seconds: 0.2, channels: 1)

        XCTAssertEqual(processor.append(systemBuffers[0], type: .audio), .recording)
        guard case .trackFailed = processor.append(microphoneBuffers[0], type: .microphone) else {
            return XCTFail("A failed microphone track must not interrupt system audio")
        }
        XCTAssertEqual(processor.append(microphoneBuffers[1], type: .microphone), .recording, "Failures are reported once")
        XCTAssertEqual(processor.append(systemBuffers[1], type: .audio), .recording)
    }

    func testCaptureIsInterruptedOnlyWhenEveryTrackFailed() {
        let processor = SystemAudioSampleProcessor()
        let missing = baseURL.appendingPathComponent("missing-directory", isDirectory: true)
        processor.configure(
            systemURL: missing.appendingPathComponent("system.m4a"),
            microphoneURL: missing.appendingPathComponent("microphone.m4a")
        )

        guard case .trackFailed = processor.append(SyntheticAudio.buffers(seconds: 0.1, channels: 1)[0], type: .microphone) else {
            return XCTFail("The first failure leaves system audio running")
        }
        guard case .allTracksFailed = processor.append(SyntheticAudio.buffers(seconds: 0.1, channels: 2)[0], type: .audio) else {
            return XCTFail("The capture ends once no track can record")
        }
    }

    // MARK: - Microphone staging and compression

    @MainActor
    func testMicrophoneStagingFormatIsReadableWhileStillOpen() throws {
        let url = baseURL.appendingPathComponent("microphone.caf")
        let file = try AVAudioFile(
            forWriting: url,
            settings: AVAudioRecorderCaptureBackend.recordingSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        try file.write(from: buffer)

        // The writer is still open, as it would be when Bardo crashes mid-recording.
        let reader = try AVAudioFile(forReading: url)
        XCTAssertGreaterThanOrEqual(Double(reader.length) / reader.processingFormat.sampleRate, 0.9)
        _ = file
    }

    func testTranscoderCompressesStagedPCMWithoutLosingDuration() async throws {
        let source = baseURL.appendingPathComponent("source.caf")
        let destination = baseURL.appendingPathComponent("compact.m4a")
        try AudioTestFixture.makeWAV(at: source, sampleRate: 48_000, duration: 2)

        try await AACAudioTranscoder().transcodeToCompactM4A(from: source, to: destination)

        let metadata = try AudioMetadataReader().read(from: destination)
        XCTAssertEqual(metadata.codec, "AAC")
        XCTAssertEqual(metadata.duration, 2, accuracy: 0.1)
        let sourceSize = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let compactSize = try XCTUnwrap(destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(compactSize, sourceSize / 4)
    }

    // MARK: - Publication

    func testOwnershipTransferRestoresSourcesWhenPublicationFails() async throws {
        let staged = baseURL.appendingPathComponent("staged.m4a")
        try AudioTestFixture.makeM4A(at: staged, duration: 0.3)
        let missing = baseURL.appendingPathComponent("never-written.m4a")
        let metadata = try AudioMetadataReader().read(from: staged)
        let first = AudioAsset(originalFileName: "a.m4a", fileExtension: "m4a", metadata: metadata, role: .systemOriginal)
        let second = AudioAsset(originalFileName: "b.m4a", fileExtension: "m4a", metadata: metadata, role: .microphoneOriginal)
        let recording = Recording(title: "Partial", sources: [.systemAudio, .microphone], audioAssets: [first, second])
        let libraryURL = baseURL.appendingPathComponent("Library", isDirectory: true)
        let store = RecordingStore(rootURL: libraryURL)

        do {
            try await store.importRecording(
                recording,
                audioFiles: [first.id: staged, second.id: missing],
                transferringOwnership: true
            )
            XCTFail("Publishing a missing source must fail")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "Moved audio must return to staging")
        XCTAssertGreaterThan(try AudioMetadataReader().read(from: staged).duration, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: libraryURL.appendingPathComponent(recording.id.uuidString).path
        ))
    }

    func testOwnershipTransferMovesInsteadOfCopying() async throws {
        let staged = baseURL.appendingPathComponent("staged.m4a")
        try AudioTestFixture.makeM4A(at: staged, duration: 0.3)
        let asset = AudioAsset(
            originalFileName: "a.m4a",
            fileExtension: "m4a",
            metadata: try AudioMetadataReader().read(from: staged),
            role: .systemOriginal
        )
        let recording = Recording(title: "Moved", sources: [.systemAudio], audioAssets: [asset])
        let store = RecordingStore(rootURL: baseURL.appendingPathComponent("Library", isDirectory: true))

        try await store.importRecording(recording, audioAsset: asset, from: staged, transferringOwnership: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let managed = try await store.managedAudioURL(recordingID: recording.id, audioAssetID: asset.id)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: managed.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.int16Value & 0o077, 0, "Managed audio must be private to the user")
    }
}

/// Synthetic 48 kHz Float32 sample buffers shaped like ScreenCaptureKit output.
enum SyntheticAudio {
    static let sampleRate = 48_000
    static let framesPerBuffer = 960

    static func buffers(seconds: Double, channels: Int, startFrame: Int64 = 0) -> [CMSampleBuffer] {
        let totalFrames = Int64(seconds * Double(sampleRate))
        var result: [CMSampleBuffer] = []
        var frame = startFrame
        while frame < startFrame + totalFrames {
            result.append(makeBuffer(startFrame: frame, frames: framesPerBuffer, channels: channels))
            frame += Int64(framesPerBuffer)
        }
        return result
    }

    static func waitForReadableDuration(at url: URL, atLeast minimum: Double) async -> Double {
        var best = 0.0
        for _ in 0..<100 {
            if let file = try? AVAudioFile(forReading: url) {
                best = max(best, Double(file.length) / file.processingFormat.sampleRate)
                if best >= minimum { return best }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return best
    }

    private static func makeBuffer(startFrame: Int64, frames: Int, channels: Int) -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )

        var samples = [Float](repeating: 0, count: frames * channels)
        for index in 0..<frames {
            let time = Double(startFrame + Int64(index)) / Double(sampleRate)
            let value = Float(sin(2 * .pi * 440 * time) * 0.2)
            for channel in 0..<channels { samples[index * channels + channel] = value }
        }

        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        )
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: block!,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }

        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: block!,
            formatDescription: format!,
            sampleCount: frames,
            presentationTimeStamp: CMTime(value: 1_000_000 + startFrame, timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer!
    }
}
