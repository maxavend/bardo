using System.Diagnostics;
using Bardo.Capture;
using Bardo.Domain;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Bardo.Audio;

/// <summary>A microphone Windows can record from.</summary>
public sealed record AudioInputDevice(string Id, string Name, bool IsDefault);

public static class AudioDevices
{
    public static IReadOnlyList<AudioInputDevice> Microphones()
    {
        using var enumerator = new MMDeviceEnumerator();
        var defaultId = enumerator.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Communications)
            ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications).ID
            : null;
        return [.. enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
            .Select(device => new AudioInputDevice(device.ID, device.FriendlyName, device.ID == defaultId))
            .OrderByDescending(device => device.IsDefault)];
    }
}

/// <summary>What to record: the microphone, the computer's audio, or both as a meeting.</summary>
public sealed record CaptureSources(bool Microphone, bool SystemAudio, string? MicrophoneDeviceId = null)
{
    public IReadOnlyList<CaptureTrackKind> Kinds =>
        [.. new[] { (Microphone, CaptureTrackKind.Microphone), (SystemAudio, CaptureTrackKind.SystemAudio) }
            .Where(source => source.Item1)
            .Select(source => source.Item2)];
}

/// <summary>
/// A recording in progress. Each source is written to its own WAV in the capture's
/// staging folder, flushed about once a second, so a crash keeps everything until then.
/// Pausing stops writing every track at once; muting the microphone writes silence so
/// the tracks keep their timing.
/// </summary>
public sealed class CaptureRecorder : IDisposable
{
    private readonly CaptureStaging _staging;
    private readonly CaptureClock _clock = new();
    private readonly List<TrackRecorder> _tracks = [];
    private readonly Lock _gate = new();
    private CaptureManifest _manifest;

    private CaptureRecorder(CaptureStaging staging, CaptureManifest manifest)
    {
        _staging = staging;
        _manifest = manifest;
    }

    public static CaptureRecorder Start(CaptureStaging staging, string title, CaptureSources sources)
    {
        var manifest = staging.Begin(title, sources.Kinds, DateTimeOffset.UtcNow);
        var recorder = new CaptureRecorder(staging, manifest);
        try
        {
            foreach (var track in manifest.Tracks)
            {
                IWaveIn capture = track.Kind == CaptureTrackKind.Microphone
                    ? new WasapiCapture(Microphone(sources.MicrophoneDeviceId), useEventSync: true, audioBufferMillisecondsLength: 100)
                    : new WasapiLoopbackCapture();
                recorder._tracks.Add(new TrackRecorder(track.Kind, capture, staging.TrackPath(manifest, track), recorder._clock));
            }
            foreach (var track in recorder._tracks) track.Start();
            return recorder;
        }
        catch
        {
            recorder.Dispose();
            staging.Discard(manifest.RecordingId);
            throw;
        }
    }

    public CaptureManifest Manifest
    {
        get
        {
            lock (_gate)
            {
                return _manifest;
            }
        }
    }

    public double Elapsed => _clock.Elapsed;

    public bool IsPaused => _clock.IsPaused;

    public bool IsMicrophoneMuted
    {
        get => Track(CaptureTrackKind.Microphone)?.IsMuted ?? false;
        set
        {
            if (Track(CaptureTrackKind.Microphone) is { } microphone) microphone.IsMuted = value;
        }
    }

    /// <summary>The loudest sample of the last buffer, 0 to 1, for the level meters.</summary>
    public float MicrophoneLevel => Track(CaptureTrackKind.Microphone)?.Level ?? 0;

    public float SystemLevel => Track(CaptureTrackKind.SystemAudio)?.Level ?? 0;

    public void Pause() => _clock.Pause();

    public void Resume() => _clock.Resume();

    public RecordingMoment AddMoment(string title, string? note) => ChangeNotes(notes => notes.AddingMoment(Elapsed, title, note));

    public RecordingSection AddSection(string title) => ChangeNotes(notes => notes.AddingSection(Elapsed, title));

    /// <summary>Stops every source, ends each track at the recording's length and returns what was captured.</summary>
    public async Task<CaptureManifest> StopAsync()
    {
        var elapsed = _clock.Elapsed;
        await Task.WhenAll(_tracks.Select(track => track.StopAsync(elapsed))).ConfigureAwait(false);
        return Manifest;
    }

    public void Dispose()
    {
        foreach (var track in _tracks) track.Dispose();
    }

    private TrackRecorder? Track(CaptureTrackKind kind) => _tracks.FirstOrDefault(track => track.Kind == kind);

    private T ChangeNotes<T>(Func<RecordingNotes, (RecordingNotes Notes, T Added)> change)
    {
        lock (_gate)
        {
            var (notes, added) = change(_manifest.Notes);
            _manifest = _manifest with { Notes = notes };
            _staging.Save(_manifest);
            return added;
        }
    }

    private static MMDevice Microphone(string? deviceId)
    {
        using var enumerator = new MMDeviceEnumerator();
        return deviceId is not null
            ? enumerator.GetDevice(deviceId)
            : enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
    }

    /// <summary>One source written to one WAV, padded with silence where the source said nothing.</summary>
    private sealed class TrackRecorder : IDisposable
    {
        private static readonly TimeSpan FlushInterval = TimeSpan.FromSeconds(1);

        private readonly IWaveIn _capture;
        private readonly WaveFileWriter _writer;
        private readonly CaptureClock _recordingClock;
        private readonly TrackClock _clock;
        private readonly Lock _gate = new();
        private readonly Stopwatch _sinceFlush = Stopwatch.StartNew();
        private readonly TaskCompletionSource _stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly int _blockAlign;
        private bool _isClosed;

        public TrackRecorder(CaptureTrackKind kind, IWaveIn capture, string path, CaptureClock recordingClock)
        {
            Kind = kind;
            _capture = capture;
            _recordingClock = recordingClock;
            _writer = new WaveFileWriter(path, capture.WaveFormat);
            _clock = new TrackClock(capture.WaveFormat.SampleRate);
            _blockAlign = capture.WaveFormat.BlockAlign;
            _capture.DataAvailable += OnDataAvailable;
            _capture.RecordingStopped += (_, _) => _stopped.TrySetResult();
        }

        public CaptureTrackKind Kind { get; }

        public bool IsMuted { get; set; }

        public float Level { get; private set; }

        public void Start() => _capture.StartRecording();

        public async Task StopAsync(double elapsed)
        {
            _capture.StopRecording();
            await Task.WhenAny(_stopped.Task, Task.Delay(TimeSpan.FromSeconds(2))).ConfigureAwait(false);
            lock (_gate)
            {
                if (_isClosed) return;
                WriteSilence(_clock.SilenceToEnd(elapsed));
                _writer.Dispose();
                _isClosed = true;
            }
        }

        public void Dispose()
        {
            _capture.DataAvailable -= OnDataAvailable;
            _capture.Dispose();
            lock (_gate)
            {
                if (_isClosed) return;
                _writer.Dispose();
                _isClosed = true;
            }
        }

        private void OnDataAvailable(object? sender, WaveInEventArgs e)
        {
            lock (_gate)
            {
                if (_isClosed || _recordingClock.IsPaused || e.BytesRecorded == 0) return;
                var frames = e.BytesRecorded / _blockAlign;
                WriteSilence(_clock.SilenceBefore(frames, _recordingClock.Elapsed));
                if (IsMuted)
                {
                    WriteSilence(frames);
                    Level = 0;
                }
                else
                {
                    _writer.Write(e.Buffer, 0, frames * _blockAlign);
                    _clock.Advance(frames);
                    Level = Peak(e.Buffer, frames * _blockAlign, _capture.WaveFormat);
                }
                if (_sinceFlush.Elapsed >= FlushInterval)
                {
                    // Updates the header sizes, so a crash loses at most this last second.
                    _writer.Flush();
                    _sinceFlush.Restart();
                }
            }
        }

        private void WriteSilence(long frames)
        {
            if (frames <= 0) return;
            var chunk = new byte[Math.Min(frames, _capture.WaveFormat.SampleRate) * _blockAlign];
            var remaining = frames;
            while (remaining > 0)
            {
                var now = Math.Min(remaining, chunk.Length / _blockAlign);
                _writer.Write(chunk, 0, (int)(now * _blockAlign));
                remaining -= now;
            }
            _clock.Advance(frames);
        }

        private static float Peak(byte[] buffer, int count, WaveFormat format)
        {
            float peak = 0;
            if (format.Encoding == WaveFormatEncoding.IeeeFloat || (format.Encoding == WaveFormatEncoding.Extensible && format.BitsPerSample == 32))
            {
                for (var i = 0; i + 4 <= count; i += 4) peak = Math.Max(peak, Math.Abs(BitConverter.ToSingle(buffer, i)));
            }
            else if (format.BitsPerSample == 16)
            {
                for (var i = 0; i + 2 <= count; i += 2) peak = Math.Max(peak, Math.Abs(BitConverter.ToInt16(buffer, i) / 32768f));
            }
            return Math.Min(1, peak);
        }
    }
}
