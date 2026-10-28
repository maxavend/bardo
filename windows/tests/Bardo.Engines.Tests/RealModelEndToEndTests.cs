using Bardo.Capture;
using Bardo.Domain;
using Bardo.Engines;
using Bardo.Library;
using Bardo.Persistence;
using Bardo.Settings;

namespace Bardo.Engines.Tests;

/// <summary>
/// Whisper and sherpa-onnx on real models and real speech, like the macOS app's
/// RealModelEndToEndTests. Opt-in: set BARDO_MODELS_DIR (holding the catalog's model files)
/// and BARDO_DIALOGUE_DIR (dialogue.wav, microphone.wav and system.wav: eight turns
/// alternating between two voices, the microphone's on even turns).
/// </summary>
[TestClass]
public sealed class RealModelEndToEndTests
{
    private static readonly string? Models = Environment.GetEnvironmentVariable("BARDO_MODELS_DIR");
    private static readonly string? Dialogue = Environment.GetEnvironmentVariable("BARDO_DIALOGUE_DIR");
    private string _library = null!;

    [TestInitialize]
    public void SetUp()
    {
        if (Models is null || Dialogue is null) Assert.Inconclusive("Set BARDO_MODELS_DIR and BARDO_DIALOGUE_DIR to run real models.");
        _library = Path.Combine(Path.GetTempPath(), $"BardoRealModels-{Guid.NewGuid()}");
        Directory.CreateDirectory(_library);
    }

    [TestCleanup]
    public void TearDown()
    {
        if (_library is not null && Directory.Exists(_library)) Directory.Delete(_library, recursive: true);
    }

    private static AudioAsset Asset(string path, AudioAssetRole role)
    {
        var format = WaveFile.ReadFormat(path);
        return new AudioAsset(Path.GetFileName(path), "wav", new AudioMetadata(WaveFile.Duration(path), "Linear PCM", format.SampleRate, (uint)format.Channels), role);
    }

    private static WhisperTranscriber Transcriber(RecordingStore store, TranscriptionTrackMode mode) =>
        new(Path.Combine(Models!, "ggml-large-v3-turbo-q5_0.bin"), TranscriptionQuality.Balanced, store, new WaveDecoder(), () => mode);

    private static SherpaSpeakerIdentifier Identifier(RecordingStore store) =>
        new(Path.Combine(Models!, "segmentation.onnx"), Path.Combine(Models!, "nemo_en_titanet_small.onnx"), store, new WaveDecoder());

    [TestMethod]
    public async Task AnImportedDialogueIsTranscribedAndItsTwoVoicesToldApart()
    {
        using var store = new RecordingStore(_library);
        var asset = Asset(Path.Combine(Dialogue!, "dialogue.wav"), AudioAssetRole.ImportedOriginal);
        var recording = new Recording("Diálogo", [AudioSource.ImportedFile], duration: asset.Metadata.Duration, audioAssets: [asset]);
        await store.ImportRecordingAsync(recording, asset, Path.Combine(Dialogue!, "dialogue.wav"));

        using var transcriber = Transcriber(store, TranscriptionTrackMode.PerTrack);
        var transcript = await transcriber.TranscribeAsync(recording, new Progress<WorkProgress>(), CancellationToken.None);

        Assert.AreEqual("es", transcript.LanguageCode);
        StringAssert.Contains(transcript.Text, "gracias por venir");
        StringAssert.Contains(transcript.Text, "barra de título");
        Assert.IsTrue(transcript.Segments.All(segment => segment.Words.Count > 0), "Every segment has its words");

        using var identifier = Identifier(store);
        var identified = await identifier.IdentifySpeakersAsync(recording, transcript, new Progress<WorkProgress>(), CancellationToken.None);

        Assert.HasCount(2, identified.Speakers);
        var turns = new TranscriptTextFormatter("Diálogo", localName: null).Blocks(identified);
        Assert.HasCount(8, turns, string.Join("\n", turns.Select(turn => $"{turn.Speaker} {turn.Start:F1}: {turn.Text}")));
        for (var index = 1; index < turns.Count; index++)
        {
            Assert.AreNotEqual(turns[index - 1].Speaker, turns[index].Speaker, "Speakers alternate turn by turn");
        }
        Assert.AreEqual(turns[0].Speaker, turns[2].Speaker);
    }

    [TestMethod]
    public async Task AMeetingIsTranscribedPerTrackAsYouAndOthers()
    {
        using var store = new RecordingStore(_library);
        var microphone = Asset(Path.Combine(Dialogue!, "microphone.wav"), AudioAssetRole.MicrophoneOriginal);
        var system = Asset(Path.Combine(Dialogue!, "system.wav"), AudioAssetRole.SystemOriginal);
        var recording = new Recording("Reunión", [AudioSource.Microphone, AudioSource.SystemAudio], duration: 44, audioAssets: [microphone, system]);
        await store.ImportRecordingAsync(recording, new Dictionary<Guid, string>
        {
            [microphone.Id] = Path.Combine(Dialogue!, "microphone.wav"),
            [system.Id] = Path.Combine(Dialogue!, "system.wav"),
        });

        using var transcriber = Transcriber(store, TranscriptionTrackMode.PerTrack);
        var transcript = await transcriber.TranscribeAsync(recording, new Progress<WorkProgress>(), CancellationToken.None);

        Assert.IsTrue(transcript.IsPerTrack);
        var turns = new TranscriptTextFormatter("Reunión", localName: "Maxi").Blocks(transcript);
        var others = transcript.DisplayName(transcript.Speakers.Single(speaker => speaker.Role == SpeakerRole.Others), localName: null);
        CollectionAssert.AreEqual(
            new[] { "Maxi", others, "Maxi", others, "Maxi", others, "Maxi", others },
            turns.Select(turn => turn.Speaker).ToArray(),
            string.Join("\n", turns.Select(turn => $"{turn.Speaker} {turn.Start:F1}: {turn.Text}")));
        StringAssert.Contains(turns[1].Text, "Perfecto");
    }
}
