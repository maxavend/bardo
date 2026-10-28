using Bardo.Diarization;
using Bardo.Domain;
using Bardo.Serialization;
using Bardo.Transcription;

namespace Bardo.Tests.Transcription;

[TestClass]
public sealed class PerTrackTranscriptionTests
{
    // Merging the tracks

    [TestMethod]
    public void MicrophoneIsYouAndComputerAudioIsOthersInTimelineOrder()
    {
        TranscriptSegment[] system = [Segment("Hola, ¿cómo estás?", 0, TranscriptSource.System)];
        TranscriptSegment[] microphone = [Segment("Muy bien, gracias", 3, TranscriptSource.Microphone)];

        var merged = TrackTranscriptMerger.Merge(system, microphone);

        CollectionAssert.AreEqual(new SpeakerRole?[] { SpeakerRole.LocalUser, SpeakerRole.Others }, merged.Speakers.Select(speaker => speaker.Role).ToArray());
        CollectionAssert.AreEqual(new[] { "Hola, ¿cómo estás?", "Muy bien, gracias" }, merged.Segments.Select(segment => segment.Text).ToArray());
        CollectionAssert.AreEqual(
            new TranscriptSource?[] { TranscriptSource.System, TranscriptSource.Microphone },
            merged.Segments.Select(segment => segment.Source).ToArray());
        Assert.AreEqual(merged.Speakers[1].Id, merged.Segments[0].SpeakerId);
        Assert.AreEqual(merged.Speakers[0].Id, merged.Segments[1].SpeakerId);
    }

    [TestMethod]
    public void OverlappingVoicesStaySeparateTurns()
    {
        TranscriptSegment[] system = [Segment("Entonces lo cerramos el viernes", 10, TranscriptSource.System)];
        TranscriptSegment[] microphone = [Segment("Perfecto, yo me encargo", 10.4, TranscriptSource.Microphone)];

        var merged = TrackTranscriptMerger.Merge(system, microphone);

        Assert.HasCount(2, merged.Segments, "Speech at the same time is kept for both people");
    }

    [TestMethod]
    public void MicrophoneEchoOfTheCallIsLeftOut()
    {
        TranscriptSegment[] system = [Segment("Esta es una prueba del audio interno del Mac", 4, TranscriptSource.System)];
        // The speakers play the call and the microphone hears it again 120 ms later.
        TranscriptSegment[] microphone = [Segment("Esta es una prueba del audio interno del Mac", 4.12, TranscriptSource.Microphone)];

        var merged = TrackTranscriptMerger.Merge(system, microphone);

        CollectionAssert.AreEqual(new TranscriptSource?[] { TranscriptSource.System }, merged.Segments.Select(segment => segment.Source).ToArray());
        CollectionAssert.AreEqual(
            new SpeakerRole?[] { SpeakerRole.Others },
            merged.Speakers.Select(speaker => speaker.Role).ToArray(),
            "No one is \"You\" when the microphone only heard the call");
    }

    [TestMethod]
    public void AcousticEchoIsLeftOutEvenWhenItsWordsDiffer()
    {
        TranscriptSegment[] system = [Segment("Nos vemos el lunes", 0, TranscriptSource.System)];
        TranscriptSegment[] microphone = [Segment("No sé de qué hablas", 0.1, TranscriptSource.Microphone)];

        var merged = TrackTranscriptMerger.Merge(system, microphone, isAcousticEcho: _ => true);

        CollectionAssert.AreEqual(new TranscriptSource?[] { TranscriptSource.System }, merged.Segments.Select(segment => segment.Source).ToArray());
    }

    [TestMethod]
    public void OwnWordsThatShareAFewWordsWithTheCallAreKept()
    {
        TranscriptSegment[] system = [Segment("¿Revisaste el prototipo de la aplicación?", 20, TranscriptSource.System)];
        var microphone = Segment("Sí, el prototipo quedó listo ayer en la tarde", 22, TranscriptSource.Microphone);

        Assert.IsFalse(TrackTranscriptMerger.IsEcho(microphone, system));
    }

    [TestMethod]
    public void EchoIsRecognisedWithoutWordTimings()
    {
        TranscriptSegment[] system = [new(0, 3, "Nos vemos el lunes", source: TranscriptSource.System)];
        var echo = new TranscriptSegment(0.1, 3.1, "nos vemos el lunes", source: TranscriptSource.Microphone);

        Assert.IsTrue(TrackTranscriptMerger.IsEcho(echo, system));
    }

    [TestMethod]
    public void EchoComparisonIgnoresAccentsAndPunctuation()
    {
        TranscriptSegment[] system = [new(0, 3, "¿Qué opinión tienes?", source: TranscriptSource.System)];
        var echo = new TranscriptSegment(0.1, 3.1, "que opinion tienes", source: TranscriptSource.Microphone);

        Assert.IsTrue(TrackTranscriptMerger.IsEcho(echo, system));
    }

    // Choosing the tracks

    [TestMethod]
    public void DualRecordingTranscribesComputerAudioThenMicrophoneWhenAskedPerTrack()
    {
        var (recording, system, microphone) = DualRecording();

        var tracks = TranscriptionAudioSelection.SeparateTracks(recording, TranscriptionTrackMode.PerTrack);

        Assert.AreEqual(system.Id, tracks?.System.Id);
        Assert.AreEqual(microphone.Id, tracks?.Microphone.Id);
        Assert.IsNull(TranscriptionAudioSelection.SeparateTracks(recording, TranscriptionTrackMode.Mix));
    }

    [TestMethod]
    public void SingleSourceRecordingNeverSplitsIntoTracks()
    {
        var asset = new AudioAsset("nota.m4a", "m4a", new AudioMetadata(30, "AAC", 48_000, 1), AudioAssetRole.MicrophoneOriginal);
        var recording = new Recording("Nota", [AudioSource.Microphone], duration: 30, audioAssets: new[] { asset });

        Assert.IsNull(TranscriptionAudioSelection.SeparateTracks(recording, TranscriptionTrackMode.PerTrack));
    }

    // Live progress

    [TestMethod]
    public void LiveProgressCountsBothPassesOverTheTimeline()
    {
        var buffer = new TranscriptionLiveBuffer(Guid.NewGuid(), audioDuration: 100, passCount: 2);

        buffer.BeginPass(0);
        var firstHalf = buffer.Merge([Segment("uno", 98, TranscriptSource.System)]);
        Assert.AreEqual(0.5, firstHalf.FractionCompleted, 0.01);

        buffer.BeginPass(1);
        var secondPass = buffer.Merge([Segment("dos", 48, TranscriptSource.Microphone)]);
        Assert.AreEqual(0.75, secondPass.FractionCompleted, 0.01);
        Assert.HasCount(2, secondPass.Segments);
    }

    // Participants

    [TestMethod]
    public void IdentifyingParticipantsOnlyTouchesTheComputerAudio()
    {
        var merged = TrackTranscriptMerger.Merge(
            [Segment("Hola equipo", 0, TranscriptSource.System), Segment("Yo presento primero", 6, TranscriptSource.System)],
            [Segment("Buenos días", 3, TranscriptSource.Microphone)]);
        var transcript = new Transcript(
            Guid.NewGuid(),
            new TranscriptMetadata("test", "1", "m", trackMode: TranscriptionTrackMode.PerTrack),
            speakers: merged.Speakers,
            segments: merged.Segments);

        var identified = TranscriptSpeakerAligner.ApplyingToOthers(
            [new DiarizationInterval(0, 0, 2.5), new DiarizationInterval(1, 5.5, 9)],
            transcript,
            new DiarizationMetadata("test", "1", "d"));

        var you = identified.Speakers.Single(speaker => speaker.Role == SpeakerRole.LocalUser);
        Assert.AreEqual(2, identified.Speakers.Count(speaker => speaker.Role is null));
        Assert.IsFalse(identified.Speakers.Any(speaker => speaker.Role == SpeakerRole.Others), "\"Others\" gives way to the participants found");
        var own = identified.Segments.Single(segment => segment.Source == TranscriptSource.Microphone);
        Assert.AreEqual("Buenos días", own.Text);
        Assert.AreEqual(you.Id, own.SpeakerId);
        Assert.IsTrue(identified.Segments.Where(segment => segment.Source != TranscriptSource.Microphone).All(segment => segment.Source == TranscriptSource.System));
        CollectionAssert.AreEqual(
            identified.Segments.Select(segment => segment.StartTime).Order().ToArray(),
            identified.Segments.Select(segment => segment.StartTime).ToArray());
    }

    [TestMethod]
    public void NamedOthersKeepTheirNameForTheFirstParticipant()
    {
        var merged = TrackTranscriptMerger.Merge(
            [Segment("Hola equipo", 0, TranscriptSource.System)],
            [Segment("Buenos días", 3, TranscriptSource.Microphone)]);
        var named = merged.Speakers.Select(speaker => speaker.Role == SpeakerRole.Others ? speaker with { Name = "Paulina" } : speaker);
        var transcript = new Transcript(
            Guid.NewGuid(),
            new TranscriptMetadata("test", "1", "m", trackMode: TranscriptionTrackMode.PerTrack),
            speakers: named.ToEquatableArray(),
            segments: merged.Segments);

        var identified = TranscriptSpeakerAligner.ApplyingToOthers(
            [new DiarizationInterval(0, 0, 2.5)],
            transcript,
            new DiarizationMetadata("test", "1", "d"));

        var participant = identified.Speakers.Single(speaker => speaker.Role is null);
        Assert.AreEqual("Paulina", participant.Name);
        Assert.AreEqual(participant.Id, identified.Segments.Single(segment => segment.Source == TranscriptSource.System).SpeakerId);
    }

    [TestMethod]
    public void PerTrackTranscriptStillOffersToIdentifyTheOthers()
    {
        var merged = TrackTranscriptMerger.Merge(
            [Segment("Hola", 0, TranscriptSource.System)],
            [Segment("Hola", 5, TranscriptSource.Microphone)]);
        var transcript = new Transcript(
            Guid.NewGuid(),
            new TranscriptMetadata("test", "1", "m", trackMode: TranscriptionTrackMode.PerTrack),
            speakers: merged.Speakers,
            segments: merged.Segments);

        Assert.AreEqual(new SpeakerNamingPresentation.IdentifySpeakers(), SpeakerNamingPolicy.Presentation(transcript));
    }

    // Compatibility

    [TestMethod]
    public void TrackDetailsSurviveSaving()
    {
        var merged = TrackTranscriptMerger.Merge(
            [Segment("Hola", 0, TranscriptSource.System)],
            [Segment("Chao", 5, TranscriptSource.Microphone)]);
        var transcript = new Transcript(
            Guid.NewGuid(),
            new TranscriptMetadata("test", "1", "m", trackMode: TranscriptionTrackMode.PerTrack),
            speakers: merged.Speakers,
            segments: merged.Segments);

        var decoded = BardoJson.Deserialize<Transcript>(BardoJson.Serialize(transcript));

        Assert.AreEqual(transcript, decoded);
        Assert.IsTrue(decoded.IsPerTrack);
    }

    internal static TranscriptSegment Segment(string text, double start, TranscriptSource source)
    {
        var tokens = text.Split(' ');
        var words = tokens.Select((token, index) => new TranscriptWord(start + index * 0.3, start + index * 0.3 + 0.25, " " + token));
        return new TranscriptSegment(start, start + tokens.Length * 0.3, text, words: words.ToEquatableArray(), source: source);
    }

    internal static (Recording Recording, AudioAsset System, AudioAsset Microphone) DualRecording()
    {
        var system = new AudioAsset("System Audio.m4a", "m4a", new AudioMetadata(30, "AAC", 48_000, 2), AudioAssetRole.SystemOriginal);
        var microphone = new AudioAsset(
            "Microphone.m4a", "m4a", new AudioMetadata(30, "AAC", 48_000, 1), AudioAssetRole.MicrophoneOriginal, timelineOffset: 0.2);
        var mix = new AudioAsset(
            "Conversation Mix.m4a",
            "m4a",
            new AudioMetadata(30.2, "AAC", 48_000, 2),
            AudioAssetRole.ConversationMix,
            derivedFromAssetIds: new[] { system.Id, microphone.Id });
        var recording = new Recording(
            "Reunión",
            [AudioSource.SystemAudio, AudioSource.Microphone],
            duration: 30.2,
            audioAssets: new[] { system, microphone, mix });
        return (recording, system, microphone);
    }
}

[TestClass]
public sealed class TrackEchoDetectorTests
{
    /// <summary>Speech-like loudness: syllables rising and falling irregularly.</summary>
    private static readonly float[] Call =
    [
        .. Enumerable.Range(0, 400).Select(index => (float)(-3 + Math.Sin(index * 0.45) + 0.6 * Math.Sin(index * 0.13))),
    ];

    [TestMethod]
    public void TheCallHeardAgainAMomentLaterIsAnEcho()
    {
        const int delayFrames = 3; // 60 ms, as measured through a Mac's speakers
        var echo = Enumerable.Repeat(-5f, delayFrames).Concat(Call.SkipLast(delayFrames).Select(level => level * 0.6f - 2));
        var segment = new TranscriptSegment(1, 5, "eco", source: TranscriptSource.Microphone);

        Assert.IsTrue(TrackEchoDetector.IsEcho(segment, new TrackLoudness(0, echo), new TrackLoudness(0, Call)));
    }

    [TestMethod]
    public void ADifferentVoiceIsNotAnEcho()
    {
        var ownVoice = Enumerable.Range(0, 400).Select(index => (float)(-3 + Math.Cos(index * 0.31) + 0.5 * Math.Sin(index * 0.07)));
        var segment = new TranscriptSegment(1, 5, "mi voz", source: TranscriptSource.Microphone);

        Assert.IsFalse(TrackEchoDetector.IsEcho(segment, new TrackLoudness(0, ownVoice), new TrackLoudness(0, Call)));
    }

    [TestMethod]
    public void NothingEchoesASilentCall()
    {
        var silence = Enumerable.Repeat(-6f, 400);
        var segment = new TranscriptSegment(1, 5, "hola", source: TranscriptSource.Microphone);

        Assert.IsFalse(TrackEchoDetector.IsEcho(segment, new TrackLoudness(0, Call), new TrackLoudness(0, silence)));
    }

    [TestMethod]
    public void LoudnessIsMeasuredEveryTwentyMillisecondsAMinuteAtATime()
    {
        var requests = new List<(double Start, double End)>();
        var loudness = TrackLoudness.Measure(
            (start, end) =>
            {
                requests.Add((start, end));
                return new float[(int)Math.Round((end - start) * TrackLoudness.SampleRate)];
            },
            duration: 90,
            offset: 1.5);

        CollectionAssert.AreEqual(new[] { (0.0, 60.0), (60.0, 90.0) }, requests);
        Assert.HasCount(4_500, loudness.Levels);
        Assert.AreEqual(-6, loudness.Levels[0], 0.001, "Silence sits at the floor");
        Assert.IsNull(loudness.LevelsFrom(1.0, 10), "Before the track starts there is nothing to compare");
        Assert.IsNotNull(loudness.LevelsFrom(1.5, 10));
    }
}
