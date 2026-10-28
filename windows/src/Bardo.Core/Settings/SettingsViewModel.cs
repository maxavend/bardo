using System.Globalization;
using Bardo.Domain;
using Bardo.Downloads;
using Bardo.Library;

namespace Bardo.Settings;

/// <summary>Which models each feature needs, and whether they are on disk.</summary>
public sealed class ModelSetup(ModelDownloader downloader)
{
    public ModelDownloader Downloader { get; } = downloader;

    public static IReadOnlyList<ModelFile> TranscriptionModels(TranscriptionQuality quality) =>
        [quality == TranscriptionQuality.Precise ? ModelCatalog.WhisperLarge : ModelCatalog.WhisperTurbo];

    public static IReadOnlyList<ModelFile> SpeakerModels { get; } = [ModelCatalog.SpeakerSegmentation, ModelCatalog.SpeakerEmbedding];

    public bool IsReady(IEnumerable<ModelFile> models) => models.All(Downloader.IsInstalled);

    public string PathFor(ModelFile model) => Downloader.PathFor(model);

    public static string Size(IEnumerable<ModelFile> models, CultureInfo? culture = null)
    {
        var bytes = models.Sum(model => model.Size);
        culture ??= CultureInfo.CurrentCulture;
        return bytes >= 1_000_000_000
            ? string.Format(culture, "{0:0.0} GB", bytes / 1e9)
            : string.Format(culture, "{0:0} MB", bytes / 1e6);
    }
}

/// <summary>Settings: your name, how recordings are kept, and how Bardo transcribes.</summary>
public sealed class SettingsViewModel : ObservableModel, IDisposable
{
    private readonly PreferencesStore _preferences;
    private readonly ModelSetup _models;
    private CancellationTokenSource? _download;
    private double _downloadProgress;
    private string? _downloadError;

    public SettingsViewModel(PreferencesStore preferences, ModelSetup models)
    {
        _preferences = preferences;
        _models = models;
    }

    /// <summary>Raised when a model was downloaded or removed, so the engines can be set up again.</summary>
    public event EventHandler? ModelsChanged;

    public string LocalName
    {
        get => _preferences.Current.LocalName ?? "";
        set => Update(current => current with { LocalName = value.Trim().Length == 0 ? null : value.Trim() });
    }

    public string? MicrophoneDeviceId
    {
        get => _preferences.Current.MicrophoneDeviceId;
        set => Update(current => current with { MicrophoneDeviceId = value });
    }

    public int AudioQualityIndex
    {
        get => (int)_preferences.Current.AudioQuality;
        set => Update(current => current with { AudioQuality = (AudioQualityPreset)Math.Clamp(value, 0, 3) });
    }

    /// <summary>Lossless keeps WAV; otherwise recordings are AAC.</summary>
    public bool KeepsLossless
    {
        get => _preferences.Current.AudioFormat != AudioStorageFormat.Aac;
        set => Update(current => current with { AudioFormat = value ? AudioStorageFormat.Wav : AudioStorageFormat.Aac });
    }

    public bool TranscribesTracksApart
    {
        get => _preferences.Current.TrackMode == TranscriptionTrackMode.PerTrack;
        set => Update(current => current with { TrackMode = value ? TranscriptionTrackMode.PerTrack : TranscriptionTrackMode.Mix });
    }

    public int TranscriptionQualityIndex
    {
        get => (int)_preferences.Current.TranscriptionQuality;
        set
        {
            Update(current => current with { TranscriptionQuality = (TranscriptionQuality)Math.Clamp(value, 0, 1) });
            NotifyModels();
            ModelsChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public bool IsTranscriptionReady => _models.IsReady(ModelSetup.TranscriptionModels(_preferences.Current.TranscriptionQuality));

    public bool IsSpeakerIdentificationReady => _models.IsReady(ModelSetup.SpeakerModels);

    public bool IsTranscriptionMissing => !IsTranscriptionReady;

    public bool IsSpeakerIdentificationMissing => !IsSpeakerIdentificationReady;

    public string TranscriptionModelSize => ModelSetup.Size(ModelSetup.TranscriptionModels(_preferences.Current.TranscriptionQuality));

    [System.Diagnostics.CodeAnalysis.SuppressMessage("Performance", "CA1822", Justification = "Bound from XAML, which reads instance properties.")]
    public string SpeakerModelSize => ModelSetup.Size(ModelSetup.SpeakerModels);

    public bool IsDownloading => _download is not null;

    public bool IsNotDownloading => _download is null;

    public double DownloadProgress => _downloadProgress;

    public string? DownloadError => _downloadError;

    public bool HasDownloadError => _downloadError is not null;

    /// <summary>Downloads what transcription and speaker identification need, as one step.</summary>
    public async Task DownloadModelsAsync()
    {
        if (_download is not null) return;
        using var cancellation = new CancellationTokenSource();
        _download = cancellation;
        SetDownload(0, error: null);
        try
        {
            var models = ModelSetup.TranscriptionModels(_preferences.Current.TranscriptionQuality)
                .Concat(ModelSetup.SpeakerModels)
                .ToList();
            await _models.Downloader.EnsureAsync(models, new Progress<double>(fraction => SetDownload(fraction, null)), cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            // Cancelled on purpose; the partial file is kept so a later download resumes.
        }
        catch (Exception error) when (error is ModelDownloadException or HttpRequestException or IOException)
        {
            SetDownload(0, error.Message);
        }
        finally
        {
            _download = null;
            OnPropertyChanged(nameof(IsDownloading));
            OnPropertyChanged(nameof(IsNotDownloading));
            NotifyModels();
            ModelsChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public void CancelDownload() => _download?.Cancel();

    public void Dispose()
    {
        _download?.Cancel();
        _download?.Dispose();
    }

    private void Update(Func<Preferences, Preferences> change)
    {
        _preferences.Update(change);
        OnPropertyChanged(string.Empty);
    }

    private void SetDownload(double progress, string? error)
    {
        _downloadProgress = progress;
        _downloadError = error;
        OnPropertyChanged(nameof(DownloadProgress));
        OnPropertyChanged(nameof(DownloadError));
        OnPropertyChanged(nameof(HasDownloadError));
        OnPropertyChanged(nameof(IsDownloading));
        OnPropertyChanged(nameof(IsNotDownloading));
    }

    private void NotifyModels()
    {
        OnPropertyChanged(nameof(IsTranscriptionReady));
        OnPropertyChanged(nameof(IsTranscriptionMissing));
        OnPropertyChanged(nameof(IsSpeakerIdentificationReady));
        OnPropertyChanged(nameof(IsSpeakerIdentificationMissing));
        OnPropertyChanged(nameof(TranscriptionModelSize));
    }
}
