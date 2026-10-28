using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Transcription;
using static Bardo.Tests.Transcription.PerTrackTranscriptionTests;

namespace Bardo.Tests.Transcription;

[TestClass]
public sealed class TranscriptionPipelineTests
{
    [TestMethod]
    public void DualCaptureUsesOnlyConversationMixForTranscription()
    {
        var system = Asset(AudioAssetRole.SystemOriginal, "system.m4a");
        var microphone = Asset(AudioAssetRole.MicrophoneOriginal, "microphone.m4a");
        var mix = Asset(AudioAssetRole.ConversationMix, "conversation.m4a", [system.Id, microphone.Id]);
        var recording = new Recording("Dual", [AudioSource.SystemAudio, AudioSource.Microphone], duration: 30, audioAssets: new[] { system, microphone, mix });

        CollectionAssert.AreEqual(new[] { mix.Id }, TranscriptionAudioSelection.Candidates(recording).Select(asset => asset.Id).ToArray());
    }

    [TestMethod]
    public void DualCaptureNeverFallsBackToSingleOriginalWhenMixIsMissing()
    {
        var system = Asset(AudioAssetRole.SystemOriginal, "system.m4a");
        var microphone = Asset(AudioAssetRole.MicrophoneOriginal, "microphone.m4a");
        var recording = new Recording("Dual without mix", [AudioSource.SystemAudio, AudioSource.Microphone], duration: 30, audioAssets: new[] { system, microphone });

        Assert.IsEmpty(TranscriptionAudioSelection.Candidates(recording));
    }

    [TestMethod]
    public async Task PerTrackPlanListensToTheComputerAudioThenTheMicrophone()
    {
        using var directory = new TemporaryDirectory();
        using var store = new RecordingStore(Path.Combine(directory.Path, "Library"));
        var (recording, system, microphone) = await ImportDualRecordingAsync(store, directory.Path);

        var plan = await TranscriptionAudioSelection.ResolvePlanAsync(recording, store, TranscriptionTrackMode.PerTrack);

        Assert.IsTrue(plan.IsPerTrack);
        CollectionAssert.AreEqual(
            new TranscriptSource?[] { TranscriptSource.System, TranscriptSource.Microphone },
            plan.Passes.Select(pass => pass.Source).ToArray());
        Assert.AreEqual(system.TimelineOffset, plan.Passes[0].Offset);
        Assert.AreEqual(microphone.TimelineOffset, plan.Passes[1].Offset);
        Assert.AreEqual(30.2, plan.TimelineDuration);
        Assert.IsTrue(plan.Passes.All(pass => File.Exists(pass.Path)));
    }

    [TestMethod]
    public async Task MixPlanListensToTheConversationMixOnce()
    {
        using var directory = new TemporaryDirectory();
        using var store = new RecordingStore(Path.Combine(directory.Path, "Library"));
        var (recording, _, _) = await ImportDualRecordingAsync(store, directory.Path);

        var plan = await TranscriptionAudioSelection.ResolvePlanAsync(recording, store, TranscriptionTrackMode.Mix);

        Assert.AreEqual(TranscriptionTrackMode.Mix, plan.TrackMode);
        Assert.HasCount(1, plan.Passes);
        Assert.IsNull(plan.Passes[0].Source);
        Assert.AreEqual(0, plan.Passes[0].Offset);
        Assert.AreEqual(30.2, plan.TimelineDuration);
    }

    [TestMethod]
    public async Task DualCaptureWithoutItsMixCannotBeTranscribedAsOne()
    {
        using var directory = new TemporaryDirectory();
        using var store = new RecordingStore(Path.Combine(directory.Path, "Library"));
        var system = Asset(AudioAssetRole.SystemOriginal, "system.m4a");
        var microphone = Asset(AudioAssetRole.MicrophoneOriginal, "microphone.m4a");
        var recording = new Recording("Dual without mix", [AudioSource.SystemAudio, AudioSource.Microphone], duration: 30, audioAssets: new[] { system, microphone });

        var error = await Assert.ThrowsExactlyAsync<TranscriptionException>(
            () => TranscriptionAudioSelection.ResolvePlanAsync(recording, store, TranscriptionTrackMode.Mix));

        Assert.AreEqual(TranscriptionErrorKind.CombinedAudioUnavailable, error.Kind);
    }

    [TestMethod]
    public async Task RecordingWithoutReadableAudioSaysSo()
    {
        using var directory = new TemporaryDirectory();
        using var store = new RecordingStore(Path.Combine(directory.Path, "Library"));
        var recording = new Recording("Nota", [AudioSource.ImportedFile], duration: 30, audioAssets: new[] { Asset(AudioAssetRole.ImportedOriginal, "nota.m4a") });

        var error = await Assert.ThrowsExactlyAsync<TranscriptionException>(
            () => TranscriptionAudioSelection.ResolvePlanAsync(recording, store, TranscriptionTrackMode.PerTrack));

        Assert.AreEqual(TranscriptionErrorKind.NoManagedAudio, error.Kind);
        Assert.AreEqual(recording.Id, error.RecordingId);
    }

    // Recognised text

    [TestMethod]
    public void RecognizedSegmentIsCleanedAndPlacedOnTheTimeline()
    {
        var pass = new TranscriptionPass("microphone.wav", 30, 0.2, TranscriptSource.Microphone);
        var recognized = new RecognizedSegment(
            1,
            2.5,
            "<|1.00|> hola equipo ... figma <|2.50|>",
            [new RecognizedWord(1, 1.4, " hola", 0.9f), new RecognizedWord(1.5, 2.5, " equipo")]);

        var segment = TranscriptionAssembly.Segment(recognized, pass);

        Assert.IsNotNull(segment);
        Assert.AreEqual("Hola equipo… Figma", segment.Text);
        Assert.AreEqual(1.2, segment.StartTime, 1e-9);
        Assert.AreEqual(2.7, segment.EndTime, 1e-9);
        Assert.AreEqual(TranscriptSource.Microphone, segment.Source);
        CollectionAssert.AreEqual(new[] { 1.2, 1.7 }, segment.Words.Select(word => Math.Round(word.StartTime, 9)).ToArray());
        Assert.AreEqual(" hola", segment.Words[0].Text, "Word tokens keep Whisper's own spacing");
        Assert.AreEqual(0.9f, segment.Words[0].Probability);
    }

    [TestMethod]
    public void SegmentWithOnlyControlTokensIsDropped()
    {
        var pass = new TranscriptionPass("mix.m4a", 30, 0, null);

        Assert.IsNull(TranscriptionAssembly.Segment(new RecognizedSegment(0, 1, " <|0.00|> <|nospeech|> "), pass));
        Assert.IsEmpty(TranscriptionAssembly.Segments([new RecognizedSegment(0, 1, "   ")], pass));
    }

    [TestMethod]
    public void SingleTrackSegmentsAreOrderedOnTheTimelineWithoutSpeakers()
    {
        var plan = new TranscriptionPlan([new TranscriptionPass("mix.m4a", 30, 0, null)], 30, TranscriptionTrackMode.Mix);
        IReadOnlyList<TranscriptSegment> heard = [new(8, 10, "Segundo"), new(2, 4, "Primero")];

        var combined = TranscriptionAssembly.Combine(plan, [heard]);

        CollectionAssert.AreEqual(new[] { "Primero", "Segundo" }, combined.Segments.Select(segment => segment.Text).ToArray());
        Assert.IsEmpty(combined.Speakers);
    }

    [TestMethod]
    public void PerTrackPassesBecomeYouAndOthersWithoutTheEcho()
    {
        var plan = new TranscriptionPlan(
            [
                new TranscriptionPass("system.m4a", 30, 0, TranscriptSource.System),
                new TranscriptionPass("microphone.m4a", 30, 0, TranscriptSource.Microphone),
            ],
            30,
            TranscriptionTrackMode.PerTrack);
        IReadOnlyList<TranscriptSegment> system = [Segment("Nos vemos el lunes entonces", 0, TranscriptSource.System)];
        IReadOnlyList<TranscriptSegment> microphone =
        [
            Segment("Nos vemos el lunes entonces", 0.1, TranscriptSource.Microphone),
            Segment("Perfecto, hasta el lunes", 4, TranscriptSource.Microphone),
        ];

        var combined = TranscriptionAssembly.Combine(plan, [system, microphone]);

        CollectionAssert.AreEqual(
            new[] { "Nos vemos el lunes entonces", "Perfecto, hasta el lunes" },
            combined.Segments.Select(segment => segment.Text).ToArray());
        Assert.HasCount(2, combined.Speakers);
        Assert.IsTrue(TranscriptionAssembly.EchoFilter(system)(microphone[0]));
        Assert.IsFalse(TranscriptionAssembly.EchoFilter(system)(microphone[1]));
    }

    [TestMethod]
    public void NothingRecognisedIsAnEmptyTranscription()
    {
        var plan = new TranscriptionPlan([new TranscriptionPass("mix.m4a", 30, 0, null)], 30, null);

        var error = Assert.ThrowsExactly<TranscriptionException>(() => TranscriptionAssembly.Combine(plan, [[]]));

        Assert.AreEqual(TranscriptionErrorKind.EmptyTranscription, error.Kind);
    }

    [TestMethod]
    public void TheTextDecidesTheLanguageWhenTheGuessIsSure()
    {
        TranscriptSegment[] segments = [new(0, 3, "Hola a todos, empecemos la reunión de hoy")];

        Assert.AreEqual("es", TranscriptionAssembly.DominantLanguage(segments, _ => new LanguageGuess("es-CL", 0.9)));
        Assert.IsNull(TranscriptionAssembly.DominantLanguage(segments, _ => new LanguageGuess("es", 0.4)));
        Assert.IsNull(TranscriptionAssembly.DominantLanguage([new TranscriptSegment(0, 1, "Hola")], _ => new LanguageGuess("es", 1)));
        Assert.AreEqual("en", TranscriptionAssembly.LanguageCode([new TranscriptSegment(0, 1, "Hola")], _ => null, ["", "en"]));
    }

    // Decoding

    [TestMethod]
    public void TranscriptionNeverConditionsTheDecoderOnAPrompt()
    {
        var settings = WhisperDecodingSettings.For(new WhisperPerformanceProfile(16UL << 30));

        Assert.IsNull(settings.Prompt, "Prompt tokens made Whisper drop the opening of each window");
        Assert.IsNull(settings.Language, "Language is detected from the audio");
        Assert.IsTrue(settings.DetectLanguage);
        Assert.IsTrue(settings.WordTimestamps, "Seeking and karaoke need word timings");
    }

    [TestMethod]
    public void RepetitiveConversationDoesNotTriggerTheLossyFallback()
    {
        var settings = WhisperDecodingSettings.For(new WhisperPerformanceProfile(16UL << 30));

        Assert.AreEqual(3.5f, settings.CompressionRatioThreshold, "Whisper's 2.4 default made the fallback drop whole turns");
        Assert.AreEqual(-1.0f, settings.LogProbThreshold, "Low-confidence windows still fall back");
        Assert.IsGreaterThan(0, settings.TemperatureFallbackCount);
    }

    [TestMethod]
    public void MicrophoneIsDecodedInTheConversationsLanguage()
    {
        var settings = WhisperDecodingSettings.For(new WhisperPerformanceProfile(8UL << 30));

        var microphone = settings.InLanguage("es");

        Assert.AreEqual("es", microphone.Language);
        Assert.IsFalse(microphone.DetectLanguage);
        Assert.AreSame(settings, settings.InLanguage(null));
    }

    [TestMethod]
    public void SixteenGigabyteProfileUsesBoundedIncrementalVadConfiguration()
    {
        var profile = new WhisperPerformanceProfile(16UL * 1_024 * 1_024 * 1_024);

        Assert.AreEqual(120, profile.IncrementalChunkDurationSeconds);
        Assert.AreEqual(2, profile.MaxBufferedChunks);
        Assert.AreEqual(8, profile.ConcurrentWorkerCount);
        Assert.IsTrue(profile.UsesVad);
        Assert.AreEqual(5, profile.TemperatureFallbackCount);
    }

    [TestMethod]
    public void MemoryConstrainedProfileReducesConcurrencyAndBuffering()
    {
        var profile = new WhisperPerformanceProfile(8UL * 1_024 * 1_024 * 1_024);

        Assert.AreEqual(90, profile.IncrementalChunkDurationSeconds);
        Assert.AreEqual(1, profile.MaxBufferedChunks);
        Assert.AreEqual(4, profile.ConcurrentWorkerCount);
    }

    // Live view

    [TestMethod]
    public void LiveBufferSortsDiscoveredSegmentsAndTracksAudioProgress()
    {
        var recordingId = Guid.NewGuid();
        var buffer = new TranscriptionLiveBuffer(recordingId, audioDuration: 20);

        var snapshot = buffer.Merge([new TranscriptSegment(8, 10, "Second"), new TranscriptSegment(2, 4, "First")]);

        Assert.AreEqual(recordingId, snapshot.RecordingId);
        CollectionAssert.AreEqual(new[] { "First", "Second" }, snapshot.Segments.Select(segment => segment.Text).ToArray());
        Assert.AreEqual(10, snapshot.ProcessedAudioTime);
        Assert.AreEqual(0.5, snapshot.FractionCompleted, 0.0001);
    }

    [TestMethod]
    public void LiveBufferReplacesRevisedSegmentWithoutChangingItsIdentity()
    {
        var buffer = new TranscriptionLiveBuffer(Guid.NewGuid(), audioDuration: 30);

        var firstSnapshot = buffer.Merge([new TranscriptSegment(1, 3, "Helo world")]);
        var firstId = firstSnapshot.Segments[0].Id;

        var revisedSnapshot = buffer.Merge([new TranscriptSegment(1, 3, "Hello world")]);

        Assert.HasCount(1, revisedSnapshot.Segments);
        Assert.AreEqual(firstId, revisedSnapshot.Segments[0].Id);
        Assert.AreEqual("Hello world", revisedSnapshot.Segments[0].Text);
    }

    [TestMethod]
    public void LiveBufferOnlyShowsProvisionalTextUntilStableSegmentsArrive()
    {
        var buffer = new TranscriptionLiveBuffer(Guid.NewGuid(), audioDuration: 30);

        var provisional = buffer.UpdateProvisionalText("  Esto todavía puede cambiar  ");
        Assert.AreEqual("Esto todavía puede cambiar", provisional.ProvisionalText);
        Assert.IsEmpty(provisional.Segments);

        var discovered = buffer.Merge([new TranscriptSegment(0, 2, "Esto ya está estable")]);
        Assert.AreEqual("", discovered.ProvisionalText);
        CollectionAssert.AreEqual(new[] { "Esto ya está estable" }, discovered.Segments.Select(segment => segment.Text).ToArray());

        var laterProgress = buffer.UpdateProvisionalText("otra hipótesis");
        Assert.AreEqual("", laterProgress.ProvisionalText);
    }

    [TestMethod]
    public void ProvisionalUpdatesAreLetThroughAtMostEveryInterval()
    {
        var limiter = new LiveUpdateRateLimiter();

        Assert.IsTrue(limiter.ShouldEmit(10));
        Assert.IsFalse(limiter.ShouldEmit(10.1));
        Assert.IsTrue(limiter.ShouldEmit(10.2));
    }

    private static AudioAsset Asset(AudioAssetRole role, string fileName, Guid[]? derivedFrom = null) =>
        new(fileName, "m4a", new AudioMetadata(30, "AAC", 48_000, role == AudioAssetRole.SystemOriginal ? 2u : 1u), role, derivedFromAssetIds: derivedFrom ?? []);

    private static async Task<(Recording Recording, AudioAsset System, AudioAsset Microphone)> ImportDualRecordingAsync(RecordingStore store, string root)
    {
        var (recording, system, microphone) = DualRecording();
        var files = new Dictionary<Guid, string>();
        foreach (var asset in recording.AudioAssets)
        {
            var source = Path.Combine(root, $"{asset.Id}.m4a");
            await File.WriteAllBytesAsync(source, [1, 2, 3]);
            files[asset.Id] = source;
        }
        await store.ImportRecordingAsync(recording, files);
        return (recording, system, microphone);
    }
}
