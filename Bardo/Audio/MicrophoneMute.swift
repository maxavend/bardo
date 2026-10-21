import CoreMedia
import Foundation

/// Silences the microphone while the recording goes on. Muted audio is replaced with
/// digital silence of the same length and timing, never dropped, so the microphone
/// track stays in step with the Mac's audio.
final class MicrophoneMute: @unchecked Sendable {
    private let lock = NSLock()
    private var muted = false

    var isMuted: Bool {
        get { lock.bardoWithLock { muted } }
        set { lock.bardoWithLock { muted = newValue } }
    }

    /// The buffer as recorded, or the same span of silence while muted.
    func apply(to sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        isMuted ? Self.silenced(sampleBuffer) : sampleBuffer
    }

    /// A copy of `sampleBuffer` with the same format, samples and timing, all zeros.
    static func silenced(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let source = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(source)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == noErr, let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr
        else { return nil }

        var timingCount: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: timingCount)
        if timingCount > 0 {
            CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: timingCount, arrayToFill: &timing, entriesNeededOut: &timingCount)
        }
        var sizeCount: CMItemCount = 0
        CMSampleBufferGetSampleSizeArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &sizeCount)
        var sizes = [Int](repeating: 0, count: sizeCount)
        if sizeCount > 0 {
            CMSampleBufferGetSampleSizeArray(sampleBuffer, entryCount: sizeCount, arrayToFill: &sizes, entriesNeededOut: &sizeCount)
        }

        var silenced: CMSampleBuffer?
        let status = timing.withUnsafeBufferPointer { timing in
            sizes.withUnsafeBufferPointer { sizes in
                CMSampleBufferCreate(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: block,
                    dataReady: true,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: CMSampleBufferGetFormatDescription(sampleBuffer),
                    sampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
                    sampleTimingEntryCount: timingCount,
                    sampleTimingArray: timingCount > 0 ? timing.baseAddress : nil,
                    sampleSizeEntryCount: sizeCount,
                    sampleSizeArray: sizeCount > 0 ? sizes.baseAddress : nil,
                    sampleBufferOut: &silenced
                )
            }
        }
        guard status == noErr else { return nil }
        return silenced
    }
}
