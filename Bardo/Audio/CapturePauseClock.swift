import CoreMedia
import Foundation

/// Lets a realtime capture pause without stopping its devices.
///
/// Audio heard while paused is dropped, and every buffer after a pause is moved back by
/// the time spent paused, so each track's file stays continuous and the two tracks keep
/// their alignment. Pauses are kept as host-time intervals: a buffer captured just
/// before a pause but delivered after it is still recorded.
final class CapturePauseClock: @unchecked Sendable {
    private let lock = NSLock()
    // Guarded by `lock`.
    private var pausedSince: CMTime?
    private var pauses: [CMTimeRange] = []

    var isPaused: Bool {
        lock.bardoWithLock { pausedSince != nil }
    }

    func pause(at time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.bardoWithLock {
            guard pausedSince == nil else { return }
            pausedSince = time
        }
    }

    func resume(at time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.bardoWithLock {
            guard let start = pausedSince else { return }
            pausedSince = nil
            if CMTimeCompare(time, start) > 0 {
                pauses.append(CMTimeRange(start: start, end: time))
            }
        }
    }

    func reset() {
        lock.bardoWithLock {
            pausedSince = nil
            pauses.removeAll()
        }
    }

    /// The buffer on the paused-free timeline, or nil when it was heard during a pause.
    func retime(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return sampleBuffer }
        guard let offset = offset(for: pts) else { return nil }
        guard CMTimeCompare(offset, .zero) > 0 else { return sampleBuffer }

        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0
        else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr else {
            return nil
        }
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, offset)
            timing[index].decodeTimeStamp = .invalid
        }
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        return retimed
    }

    /// The paused time before `time`, or nil when `time` falls inside a pause.
    func offset(for time: CMTime) -> CMTime? {
        lock.bardoWithLock {
            if let pausedSince, CMTimeCompare(time, pausedSince) >= 0 { return nil }
            var offset = CMTime.zero
            for pause in pauses {
                if pause.containsTime(time) { return nil }
                if CMTimeCompare(pause.end, time) <= 0 {
                    offset = CMTimeAdd(offset, pause.duration)
                }
            }
            return offset
        }
    }
}
