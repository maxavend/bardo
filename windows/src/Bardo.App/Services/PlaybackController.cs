using Bardo.Domain;
using Bardo.Library;
using Bardo.Persistence;
using Microsoft.UI.Dispatching;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace Bardo.App.Services;

/// <summary>
/// Plays the selected conversation with Windows' media player: its conversation mix
/// when it has one, otherwise its original. Position updates arrive on the window's thread.
/// </summary>
public sealed class PlaybackController : ObservableModel, IDisposable
{
    private readonly MediaPlayer _player = new() { AutoPlay = false };
    private readonly DispatcherQueue _dispatcher;
    private readonly RecordingStore _store;
    private Guid? _recordingId;
    private double _position;
    private double _duration;
    private bool _isPlaying;
    private bool _isAvailable;

    public PlaybackController(DispatcherQueue dispatcher, RecordingStore store)
    {
        _dispatcher = dispatcher;
        _store = store;
        _player.PlaybackSession.PositionChanged += (session, _) => OnPlayer(() => Position = session.Position.TotalSeconds);
        _player.PlaybackSession.PlaybackStateChanged += (session, _) =>
            OnPlayer(() => IsPlaying = session.PlaybackState == MediaPlaybackState.Playing);
        _player.MediaOpened += (player, _) => OnPlayer(() => Duration = player.PlaybackSession.NaturalDuration.TotalSeconds);
    }

    public bool IsAvailable
    {
        get => _isAvailable;
        private set => SetProperty(ref _isAvailable, value);
    }

    public bool IsPlaying
    {
        get => _isPlaying;
        private set
        {
            if (SetProperty(ref _isPlaying, value)) OnPropertyChanged(nameof(PlayGlyph));
        }
    }

    /// <summary>Segoe Fluent Icons: pause while playing, play otherwise.</summary>
    public string PlayGlyph => IsPlaying ? "" : "";

    public double Position
    {
        get => _position;
        private set
        {
            if (SetProperty(ref _position, value)) OnPropertyChanged(nameof(PositionText));
        }
    }

    public double Duration
    {
        get => _duration;
        private set
        {
            if (SetProperty(ref _duration, Math.Max(value, 0.01))) OnPropertyChanged(nameof(DurationText));
        }
    }

    public string PositionText => DurationFormatting.Duration(Position);

    public string DurationText => DurationFormatting.Duration(Duration);

    public async Task LoadAsync(Recording? recording)
    {
        if (recording?.Id == _recordingId) return;
        _player.Pause();
        _recordingId = recording?.Id;
        Position = 0;
        Duration = recording?.Duration ?? 0;
        IsAvailable = false;
        _player.Source = null;
        if (recording?.PlaybackAudioAssets.FirstOrDefault() is not { } asset) return;
        try
        {
            var path = await _store.ManagedAudioPathAsync(recording.Id, asset.Id);
            if (_recordingId != recording.Id) return;
            _player.Source = MediaSource.CreateFromUri(new Uri(path));
            IsAvailable = true;
        }
        catch (RecordingStoreException)
        {
            // Missing audio is reported by the Library; there is nothing to play.
        }
    }

    public void TogglePlay()
    {
        if (!IsAvailable) return;
        if (IsPlaying) _player.Pause();
        else _player.Play();
    }

    public void Seek(double seconds, bool play = false)
    {
        if (!IsAvailable) return;
        _player.PlaybackSession.Position = TimeSpan.FromSeconds(Math.Clamp(seconds, 0, Duration));
        Position = seconds;
        if (play) _player.Play();
    }

    public void SkipBy(double seconds) => Seek(Position + seconds);

    public void Dispose() => _player.Dispose();

    private void OnPlayer(Action update) => _dispatcher.TryEnqueue(() => update());
}
