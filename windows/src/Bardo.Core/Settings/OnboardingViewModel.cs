using Bardo.Library;

namespace Bardo.Settings;

/// <summary>Where first-run setup stands.</summary>
public enum OnboardingState
{
    /// <summary>Choosing between Recommended and Precise.</summary>
    Choosing,
    Downloading,
    /// <summary>Stopped on purpose; what was downloaded is kept.</summary>
    Paused,
    Failed,
    Ready,
}

/// <summary>
/// First-run setup: choose how Bardo transcribes and download its models once. It never
/// locks the app: it can be set aside, and a download set aside carries on in the
/// background, as on macOS.
/// </summary>
public sealed class OnboardingViewModel : ObservableModel
{
    private readonly PreferencesStore _preferences;
    private readonly SettingsViewModel _settings;
    private OnboardingState _state = OnboardingState.Choosing;
    private bool _isOpen;

    public OnboardingViewModel(PreferencesStore preferences, SettingsViewModel settings)
    {
        _preferences = preferences;
        _settings = settings;
        _isOpen = !preferences.Current.HasFinishedSetup && !(settings.IsTranscriptionReady && settings.IsSpeakerIdentificationReady);
        settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(SettingsViewModel.DownloadProgress)) OnPropertyChanged(nameof(Progress));
        };
    }

    public bool IsOpen
    {
        get => _isOpen;
        private set => SetProperty(ref _isOpen, value);
    }

    public OnboardingState State
    {
        get => _state;
        private set
        {
            if (!SetProperty(ref _state, value)) return;
            OnPropertyChanged(nameof(IsChoosing));
            OnPropertyChanged(nameof(IsDownloading));
            OnPropertyChanged(nameof(IsPaused));
            OnPropertyChanged(nameof(HasFailed));
            OnPropertyChanged(nameof(IsReady));
            OnPropertyChanged(nameof(ShowsProgress));
        }
    }

    public bool IsChoosing => State == OnboardingState.Choosing;
    public bool IsDownloading => State == OnboardingState.Downloading;
    public bool IsPaused => State == OnboardingState.Paused;
    public bool HasFailed => State == OnboardingState.Failed;
    public bool IsReady => State == OnboardingState.Ready;
    public bool ShowsProgress => State is OnboardingState.Downloading or OnboardingState.Paused;

    public bool IsRecommendedChosen
    {
        get => _settings.TranscriptionQualityIndex == (int)TranscriptionQuality.Balanced;
        set
        {
            if (!value) return;
            _settings.TranscriptionQualityIndex = (int)TranscriptionQuality.Balanced;
            OnPropertyChanged();
            OnPropertyChanged(nameof(IsPreciseChosen));
        }
    }

    public bool IsPreciseChosen
    {
        get => _settings.TranscriptionQualityIndex == (int)TranscriptionQuality.Precise;
        set
        {
            if (!value) return;
            _settings.TranscriptionQualityIndex = (int)TranscriptionQuality.Precise;
            OnPropertyChanged();
            OnPropertyChanged(nameof(IsRecommendedChosen));
        }
    }

    /// <summary>What each choice downloads, speakers included: "620 MB", "1,1 GB".</summary>
    public string RecommendedSize { get; } = Size(TranscriptionQuality.Balanced);

    public string PreciseSize { get; } = Size(TranscriptionQuality.Precise);

    public double Progress => _settings.DownloadProgress;

    public string? Error => _settings.DownloadError;

    /// <summary>Downloads the chosen models. A pause or a failure can be resumed where it stopped.</summary>
    public async Task DownloadAsync()
    {
        if (IsDownloading) return;
        State = OnboardingState.Downloading;
        await _settings.DownloadModelsAsync();
        State = _settings.IsTranscriptionReady && _settings.IsSpeakerIdentificationReady
            ? OnboardingState.Ready
            : _settings.HasDownloadError ? OnboardingState.Failed : OnboardingState.Paused;
        OnPropertyChanged(nameof(Error));
        if (IsReady) _preferences.Update(current => current with { HasFinishedSetup = true });
    }

    public void Pause() => _settings.CancelDownload();

    /// <summary>Closes setup; a download in progress carries on, and Settings shows it.</summary>
    public void Close()
    {
        _preferences.Update(current => current with { HasFinishedSetup = true });
        IsOpen = false;
    }

    /// <summary>Shows a state without downloading, for design reviews.</summary>
    public void Preview(OnboardingState state, double progress = 0)
    {
        _settings.PreviewDownload(progress);
        IsOpen = true;
        State = state;
        OnPropertyChanged(nameof(Progress));
    }

    private static string Size(TranscriptionQuality quality) =>
        ModelSetup.Size(ModelSetup.TranscriptionModels(quality).Concat(ModelSetup.SpeakerModels));
}
