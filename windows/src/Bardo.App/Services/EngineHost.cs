using Bardo.Audio;
using Bardo.Downloads;
using Bardo.Engines;
using Bardo.Library;
using Bardo.Settings;

namespace Bardo.App.Services;

/// <summary>
/// Gives the Library its engines once their models are on disk, and sets them up again
/// when Settings change the model. The Library never waits for them.
/// </summary>
internal sealed class EngineHost(LibraryViewModel library, ModelSetup models, PreferencesStore preferences) : IDisposable
{
    private readonly MediaFoundationDecoder _decoder = new();
    private WhisperTranscriber? _transcriber;
    private SherpaSpeakerIdentifier? _identifier;

    public void Refresh()
    {
        var quality = preferences.Current.TranscriptionQuality;
        var whisper = ModelSetup.TranscriptionModels(quality);
        if (library.IsWorking) return;

        _transcriber?.Dispose();
        _transcriber = models.IsReady(whisper)
            ? new WhisperTranscriber(models.PathFor(whisper[0]), quality, library.RecordingStore, _decoder, () => preferences.Current.TrackMode)
            : null;
        library.Transcriber = _transcriber;

        _identifier?.Dispose();
        _identifier = models.IsReady(ModelSetup.SpeakerModels)
            ? new SherpaSpeakerIdentifier(
                models.PathFor(ModelCatalog.SpeakerSegmentation),
                models.PathFor(ModelCatalog.SpeakerEmbedding),
                library.RecordingStore,
                _decoder)
            : null;
        library.SpeakerIdentifier = _identifier;
    }

    public void Dispose()
    {
        _transcriber?.Dispose();
        _identifier?.Dispose();
    }
}
