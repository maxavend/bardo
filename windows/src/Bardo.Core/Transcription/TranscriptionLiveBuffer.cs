using System.Diagnostics;
using Bardo.Domain;
using Bardo.Serialization;

namespace Bardo.Transcription;

/// <summary>
/// Collects what a transcription recognises as it goes, from any thread. A segment the
/// recogniser revises keeps its identity, so the live view updates it in place.
/// </summary>
public sealed class TranscriptionLiveBuffer
{
    private readonly record struct SegmentKey(long StartMilliseconds, long EndMilliseconds, TranscriptSource? Source)
    {
        public SegmentKey(TranscriptSegment segment)
            : this(
                (long)Math.Round(segment.StartTime * 1_000, MidpointRounding.AwayFromZero),
                (long)Math.Round(segment.EndTime * 1_000, MidpointRounding.AwayFromZero),
                segment.Source)
        {
        }
    }

    private readonly Lock _gate = new();
    private readonly Guid _recordingId;
    private readonly double _audioDuration;
    private readonly int _passCount;
    private readonly Dictionary<SegmentKey, TranscriptSegment> _segmentsByKey = [];
    private string _provisionalText = "";
    private int _pass;
    private double _passProcessedTime;

    /// <summary>
    /// <paramref name="passCount"/> is how many times the timeline is listened to: once for
    /// one track, twice when the microphone and the computer's audio are transcribed apart.
    /// </summary>
    public TranscriptionLiveBuffer(Guid recordingId, double audioDuration, int passCount = 1)
    {
        _recordingId = recordingId;
        _audioDuration = audioDuration;
        _passCount = Math.Max(1, passCount);
    }

    /// <summary>Starts listening to the timeline again for the next track.</summary>
    public TranscriptionLiveSnapshot BeginPass(int index)
    {
        lock (_gate)
        {
            _pass = Math.Min(Math.Max(0, index), _passCount - 1);
            _passProcessedTime = 0;
            return MakeSnapshot();
        }
    }

    /// <summary>The recogniser's current guess, shown only until the first stable segment arrives.</summary>
    public TranscriptionLiveSnapshot UpdateProvisionalText(string text)
    {
        lock (_gate)
        {
            _provisionalText = _segmentsByKey.Count == 0
                ? TranscriptTextSanitizer.NormalizeRecognizedText(text).Trim()
                : "";
            return MakeSnapshot();
        }
    }

    public TranscriptionLiveSnapshot Merge(IEnumerable<TranscriptSegment> segments)
    {
        lock (_gate)
        {
            foreach (var segment in segments)
            {
                var key = new SegmentKey(segment);
                var existingId = _segmentsByKey.TryGetValue(key, out var existing) ? existing.Id : segment.Id;
                _segmentsByKey[key] = new TranscriptSegment(
                    segment.StartTime,
                    segment.EndTime,
                    segment.Text,
                    segment.SpeakerId,
                    segment.Words,
                    segment.EditedText,
                    segment.Source,
                    existingId);
                _passProcessedTime = Math.Max(_passProcessedTime, segment.EndTime);
            }

            if (_segmentsByKey.Count > 0) _provisionalText = "";
            return MakeSnapshot();
        }
    }

    public TranscriptionLiveSnapshot Snapshot()
    {
        lock (_gate)
        {
            return MakeSnapshot();
        }
    }

    private TranscriptionLiveSnapshot MakeSnapshot()
    {
        var sortedSegments = _segmentsByKey.Values
            .OrderBy(segment => segment.StartTime)
            .ThenBy(segment => segment.EndTime)
            .ToEquatableArray();
        // Every pass covers the whole timeline, so progress counts finished passes in full.
        var passTime = Math.Min(_passProcessedTime, _audioDuration);
        var processedAudioTime = (_pass * _audioDuration + passTime) / _passCount;

        return new TranscriptionLiveSnapshot(_recordingId, sortedSegments, _provisionalText, processedAudioTime, _audioDuration);
    }
}

/// <summary>
/// Lets a stream of provisional updates through at most every <c>minimumInterval</c>, so
/// the recogniser's per-token guesses do not flood the live view.
/// </summary>
public sealed class LiveUpdateRateLimiter
{
    public static readonly TimeSpan DefaultMinimumInterval = TimeSpan.FromSeconds(0.12);

    private readonly Lock _gate = new();
    private readonly double _minimumInterval;
    private double? _lastEmission;

    public LiveUpdateRateLimiter(TimeSpan? minimumInterval = null)
    {
        _minimumInterval = (minimumInterval ?? DefaultMinimumInterval).TotalSeconds;
    }

    public bool ShouldEmit() => ShouldEmit(Stopwatch.GetElapsedTime(0).TotalSeconds);

    /// <param name="now">Seconds on any monotonic clock.</param>
    public bool ShouldEmit(double now)
    {
        lock (_gate)
        {
            if (_lastEmission is not { } last)
            {
                _lastEmission = now;
                return true;
            }
            if (now - last < _minimumInterval) return false;
            _lastEmission = now;
            return true;
        }
    }
}
