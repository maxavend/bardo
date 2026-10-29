namespace Bardo.Capture;

/// <summary>
/// Keeps a captured track on the recording's timeline. System audio delivers nothing
/// while the computer is silent, and a device can start late; the clock says how many
/// frames of silence to write first so every track stays as long as the recording.
/// Paused time does not count.
/// </summary>
public sealed class TrackClock(int sampleRate)
{
    /// <summary>Gaps shorter than this are device jitter, not silence.</summary>
    public const double Tolerance = 0.05;

    public long WrittenFrames { get; private set; }

    public int SampleRate { get; } = sampleRate;

    public double WrittenSeconds => (double)WrittenFrames / SampleRate;

    /// <summary>
    /// Frames of silence to write before <paramref name="incomingFrames"/> that arrive when
    /// <paramref name="elapsedSeconds"/> of the recording have passed.
    /// </summary>
    public long SilenceBefore(long incomingFrames, double elapsedSeconds)
    {
        var expectedStart = (long)Math.Round(elapsedSeconds * SampleRate) - incomingFrames;
        var gap = expectedStart - WrittenFrames;
        return gap > Tolerance * SampleRate ? gap : 0;
    }

    /// <summary>Frames of silence that bring the track to <paramref name="elapsedSeconds"/> when it ends.</summary>
    public long SilenceToEnd(double elapsedSeconds) =>
        Math.Max(0, (long)Math.Round(elapsedSeconds * SampleRate) - WrittenFrames);

    public void Advance(long frames) => WrittenFrames += frames;
}

/// <summary>The recording's own time: wall time minus pauses.</summary>
public sealed class CaptureClock(Func<TimeSpan> now)
{
    private TimeSpan _pausedTotal;
    private TimeSpan? _pausedAt;

    public CaptureClock() : this(StopwatchNow())
    {
    }

    public bool IsPaused => _pausedAt is not null;

    public double Elapsed => ((_pausedAt ?? now()) - _pausedTotal).TotalSeconds;

    public void Pause() => _pausedAt ??= now();

    public void Resume()
    {
        if (_pausedAt is not { } pausedAt) return;
        _pausedTotal += now() - pausedAt;
        _pausedAt = null;
    }

    private static Func<TimeSpan> StopwatchNow()
    {
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        return () => stopwatch.Elapsed;
    }
}
