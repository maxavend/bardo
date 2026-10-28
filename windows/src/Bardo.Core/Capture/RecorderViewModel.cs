using System.Collections.ObjectModel;
using Bardo.Domain;
using Bardo.Library;

namespace Bardo.Capture;

/// <summary>What to record.</summary>
public enum CaptureMode
{
    /// <summary>The microphone alone: a voice memo or an in-person conversation.</summary>
    Microphone,

    /// <summary>The computer's audio alone, such as a talk or a video.</summary>
    SystemAudio,

    /// <summary>A call: the microphone and the computer's audio, kept as separate tracks.</summary>
    Meeting,
}

/// <summary>A capture in progress, as the recorder drives it. Implemented with WASAPI on Windows.</summary>
public interface ICaptureSession : IDisposable
{
    CaptureManifest Manifest { get; }
    double Elapsed { get; }
    bool IsPaused { get; }
    bool IsMicrophoneMuted { get; set; }
    float MicrophoneLevel { get; }
    float SystemLevel { get; }
    void Pause();
    void Unpause();
    RecordingMoment AddMoment(string title, string? note);
    RecordingSection AddSection(string title);
    Task<CaptureManifest> StopAsync();
}

/// <summary>Starts captures and turns them into Library recordings.</summary>
public interface ICaptureService
{
    ICaptureSession Start(CaptureMode mode, string? microphoneDeviceId);
    Task<Recording?> PublishAsync(CaptureManifest manifest, AudioEncoding encoding, CancellationToken cancellationToken);
    IReadOnlyList<CaptureManifest> Interrupted();
    void Discard(CaptureManifest manifest);
}

/// <summary>A moment or section marked while recording, as the recorder lists it.</summary>
public sealed record MarkRow(string Time, string Title, bool IsSection);

/// <summary>
/// The live recorder: its clock, levels, pause and mute, and the moments and sections
/// marked along the way. The window calls <see cref="Tick"/> on every frame it draws.
/// </summary>
public sealed class RecorderViewModel(ICaptureService service) : ObservableModel
{
    private ICaptureSession? _session;
    private bool _isFinishing;
    private string _elapsed = DurationFormatting.Duration(0);
    private float _microphoneLevel;
    private float _systemLevel;

    public ObservableCollection<MarkRow> Marks { get; } = [];

    public bool IsRecording => _session is not null;

    public bool IsFinishing => _isFinishing;

    public bool IsPaused => _session?.IsPaused ?? false;

    public bool IsMicrophoneMuted
    {
        get => _session?.IsMicrophoneMuted ?? false;
        set
        {
            if (_session is null || _session.IsMicrophoneMuted == value) return;
            _session.IsMicrophoneMuted = value;
            OnPropertyChanged();
        }
    }

    public bool HasMicrophone => _session?.Manifest.Tracks.Any(track => track.Kind == CaptureTrackKind.Microphone) ?? false;

    public bool HasSystemAudio => _session?.Manifest.Tracks.Any(track => track.Kind == CaptureTrackKind.SystemAudio) ?? false;

    public string ElapsedText => _elapsed;

    public double MicrophoneLevel => _microphoneLevel;

    public double SystemLevel => _systemLevel;

    public void Start(CaptureMode mode, string? microphoneDeviceId)
    {
        if (_session is not null) return;
        _session = service.Start(mode, microphoneDeviceId);
        Marks.Clear();
        NotifyAll();
    }

    public void Tick()
    {
        if (_session is not { } session) return;
        var elapsed = DurationFormatting.Duration(Math.Floor(session.Elapsed));
        SetProperty(ref _elapsed, elapsed, nameof(ElapsedText));
        SetProperty(ref _microphoneLevel, session.IsMicrophoneMuted ? 0 : session.MicrophoneLevel, nameof(MicrophoneLevel));
        SetProperty(ref _systemLevel, session.SystemLevel, nameof(SystemLevel));
    }

    public void TogglePause()
    {
        if (_session is not { } session) return;
        if (session.IsPaused) session.Unpause();
        else session.Pause();
        OnPropertyChanged(nameof(IsPaused));
    }

    public void AddMoment(string title = "", string? note = null)
    {
        if (_session is not { } session) return;
        var moment = session.AddMoment(title, note);
        Marks.Add(new MarkRow(DurationFormatting.Duration(moment.Time), moment.Title, IsSection: false));
    }

    public void AddSection(string title = "")
    {
        if (_session is not { } session) return;
        var section = session.AddSection(title);
        Marks.Add(new MarkRow(DurationFormatting.Duration(section.Start), section.Title, IsSection: true));
    }

    /// <summary>Stops, and publishes the recording to the Library. Null when nothing was captured.</summary>
    public async Task<Recording?> StopAsync(AudioEncoding encoding)
    {
        if (_session is not { } session || _isFinishing) return null;
        _isFinishing = true;
        OnPropertyChanged(nameof(IsFinishing));
        try
        {
            var manifest = await session.StopAsync();
            session.Dispose();
            return await service.PublishAsync(manifest, encoding, CancellationToken.None);
        }
        finally
        {
            _session = null;
            _isFinishing = false;
            _elapsed = DurationFormatting.Duration(0);
            _microphoneLevel = 0;
            _systemLevel = 0;
            NotifyAll();
        }
    }

    private void NotifyAll()
    {
        OnPropertyChanged(nameof(IsRecording));
        OnPropertyChanged(nameof(IsFinishing));
        OnPropertyChanged(nameof(IsPaused));
        OnPropertyChanged(nameof(IsMicrophoneMuted));
        OnPropertyChanged(nameof(HasMicrophone));
        OnPropertyChanged(nameof(HasSystemAudio));
        OnPropertyChanged(nameof(ElapsedText));
        OnPropertyChanged(nameof(MicrophoneLevel));
        OnPropertyChanged(nameof(SystemLevel));
    }
}
