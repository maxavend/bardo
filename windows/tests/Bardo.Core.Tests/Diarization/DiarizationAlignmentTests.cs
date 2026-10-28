using Bardo.Diarization;
using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Transcription;
using Bardo.Tests.Transcription;

namespace Bardo.Tests.Diarization;

[TestClass]
public sealed class DiarizationAlignmentTests
{
    private static DiarizationMetadata Metadata() => new("sherpa-onnx", "1", "pyannote");

    private static TranscriptMetadata Whisper() => new("Whisper.net", "1", TranscriptionSelection.TurboModelId);

    [TestMethod]
    public void CrossSpeakerWhisperSegmentIsRebuiltAtWordBoundaries()
    {
        var transcript = new Transcript(Guid.NewGuid(), Whisper(), segments: new[]
        {
            new TranscriptSegment(0, 3, "Hello yes", words: new[] { new TranscriptWord(0, 0.4, "Hello"), new TranscriptWord(0.5, 0.9, " yes") }),
        });

        var aligned = TranscriptSpeakerAligner.Applying([new(0, 0, 0.45), new(1, 0.45, 1.2)], transcript, Metadata());

        Assert.HasCount(2, aligned.Segments);
        CollectionAssert.AreEqual(new[] { "Hello", "yes" }, aligned.Segments.Select(segment => segment.Text).ToArray());
        CollectionAssert.AreEqual(new[] { 1, 1 }, aligned.Segments.Select(segment => segment.Words.Count).ToArray());
        Assert.AreNotEqual(aligned.Segments[0].SpeakerId, aligned.Segments[1].SpeakerId);
    }

    [TestMethod]
    public void AToBToAConversationKeepsThreeTurns()
    {
        TranscriptWord[] words =
        [
            new(0, 0.2, "A"), new(0.3, 0.5, "one"),
            new(1, 1.2, "B"), new(1.3, 1.5, "reply"),
            new(2, 2.2, "A"), new(2.3, 2.5, "again"),
        ];
        var transcript = new Transcript(Guid.NewGuid(), Whisper(), segments: new[] { new TranscriptSegment(0, 3, "A one B reply A again", words: words) });

        var aligned = TranscriptSpeakerAligner.Applying([new(0, 0, 0.8), new(1, 0.8, 1.8), new(0, 1.8, 3)], transcript, Metadata());

        Assert.HasCount(3, aligned.Segments);
        CollectionAssert.AreEqual(new[] { "A one", "B reply", "A again" }, aligned.Segments.Select(segment => segment.Text).ToArray());
        Assert.AreEqual(aligned.Segments[0].SpeakerId, aligned.Segments[2].SpeakerId);
        Assert.AreEqual(Metadata().ModelId, aligned.DiarizationMetadata?.ModelId);
    }

    [TestMethod]
    public void ManualTextEditsAndOldSegmentBoundariesSurviveRediarization()
    {
        var segmentId = Guid.NewGuid();
        var transcript = new Transcript(Guid.NewGuid(), Whisper(), segments: new[]
        {
            new TranscriptSegment(0, 2, "Original", words: new[] { new TranscriptWord(0, 1, "Original") }, editedText: "Human correction", id: segmentId),
        });

        var aligned = TranscriptSpeakerAligner.Applying([new(0, 0, 2)], transcript, Metadata());

        CollectionAssert.AreEqual(new[] { segmentId }, aligned.Segments.Select(segment => segment.Id).ToArray());
        Assert.AreEqual("Human correction", aligned.Segments[0].DisplayText);
        Assert.AreEqual("Human correction", aligned.Segments[0].EditedText);
        Assert.AreEqual(aligned.Speakers[0].Id, aligned.Segments[0].SpeakerId);
    }

    [TestMethod]
    public void NoSpeakerOverlapLeavesSegmentUnassigned()
    {
        var transcript = new Transcript(Guid.NewGuid(), Whisper(), segments: new[] { new TranscriptSegment(10, 11, "Silence") });

        var aligned = TranscriptSpeakerAligner.Applying([new(0, 0, 1)], transcript, Metadata());

        Assert.IsNull(aligned.Segments[0].SpeakerId);
    }

    [TestMethod]
    public void NoUsableIntervalMeansNoSpeakerActivity()
    {
        var transcript = new Transcript(Guid.NewGuid(), Whisper(), segments: new[] { new TranscriptSegment(0, 1, "Hola") });

        var error = Assert.ThrowsExactly<DiarizationException>(
            () => TranscriptSpeakerAligner.Applying([new(-1, 0, 1), new(0, 2, 2), new(1, double.NaN, 3)], transcript, Metadata()));

        Assert.AreEqual(DiarizationErrorKind.NoSpeakerActivity, error.Kind);
    }

    [TestMethod]
    public void RediarizationKeepsNamedSpeakersInOrderOfAppearance()
    {
        var ana = new Speaker(name: "Ana");
        var luis = new Speaker(name: "Luis");
        var transcript = new Transcript(
            Guid.NewGuid(),
            Whisper(),
            speakers: new[] { ana, luis },
            segments: new[]
            {
                new TranscriptSegment(0, 1, "Hola", speakerId: luis.Id),
                new TranscriptSegment(2, 3, "Chao", speakerId: ana.Id),
            });

        var aligned = TranscriptSpeakerAligner.Applying([new(5, 0, 1), new(2, 2, 3)], transcript, Metadata());

        CollectionAssert.AreEqual(new[] { "Luis", "Ana" }, aligned.Speakers.Select(speaker => speaker.Name).ToArray());
        CollectionAssert.AreEqual(new Guid?[] { luis.Id, ana.Id }, aligned.Segments.Select(segment => segment.SpeakerId).ToArray());
    }

    [TestMethod]
    public void EngineTurnsArePlacedOnTheTimelineAndUnassignedOnesDropped()
    {
        var intervals = TranscriptSpeakerAligner.Intervals([new SpeakerTurn(0, 1, 2), new SpeakerTurn(null, 2, 3)], timelineOffset: 0.5);

        CollectionAssert.AreEqual(new[] { new DiarizationInterval(0, 1.5, 2.5) }, intervals.ToArray());
    }

    [TestMethod]
    public async Task PerTrackTranscriptListensOnlyToTheComputerAudio()
    {
        using var directory = new TemporaryDirectory();
        using var store = new RecordingStore(Path.Combine(directory.Path, "Library"));
        var (recording, system, _) = PerTrackTranscriptionTests.DualRecording();
        var files = new Dictionary<Guid, string>();
        foreach (var asset in recording.AudioAssets)
        {
            files[asset.Id] = Path.Combine(directory.Path, $"{asset.Id}.m4a");
            await File.WriteAllBytesAsync(files[asset.Id], [1, 2, 3]);
        }
        await store.ImportRecordingAsync(recording, files);
        var perTrack = new Transcript(recording.Id, new TranscriptMetadata("test", "1", "m", trackMode: TranscriptionTrackMode.PerTrack));
        var mixed = new Transcript(recording.Id, new TranscriptMetadata("test", "1", "m", trackMode: TranscriptionTrackMode.Mix));

        var others = await DiarizationAudio.ResolveAsync(recording, perTrack, store);
        var whole = await DiarizationAudio.ResolveAsync(recording, mixed, store);

        Assert.IsTrue(others.IsOthersTrack);
        Assert.AreEqual(system.TimelineOffset, others.TimelineOffset);
        Assert.AreEqual(await store.ManagedAudioPathAsync(recording.Id, system.Id), others.Path);
        Assert.IsFalse(whole.IsOthersTrack);
        Assert.AreEqual(30.2, whole.Duration);
    }
}

[TestClass]
public sealed class SpeakerNamingPolicyTests
{
    [TestMethod]
    public void OneSpeakerIsNonActionableAndDoesNotOpenNamingFlow()
    {
        var transcript = MakeTranscript(new Speaker());

        Assert.AreEqual(new SpeakerNamingPresentation.SingleSpeaker(), SpeakerNamingPolicy.Presentation(transcript));
        Assert.IsFalse(SpeakerNamingPolicy.ShouldOpenNamingFlow(transcript));
    }

    [TestMethod]
    public void TwoSpeakersShowParticipantsAndAllowNamingFlow()
    {
        var transcript = MakeTranscript(new Speaker(), new Speaker());

        Assert.AreEqual(new SpeakerNamingPresentation.Participants(2), SpeakerNamingPolicy.Presentation(transcript));
        Assert.IsTrue(SpeakerNamingPolicy.ShouldOpenNamingFlow(transcript));
    }

    [TestMethod]
    public void NoSpeakersRequestsSpeakerIdentification()
    {
        var transcript = MakeTranscript();

        Assert.AreEqual(new SpeakerNamingPresentation.IdentifySpeakers(), SpeakerNamingPolicy.Presentation(transcript));
        Assert.IsFalse(SpeakerNamingPolicy.ShouldOpenNamingFlow(transcript));
    }

    private static Transcript MakeTranscript(params Speaker[] speakers) =>
        new(Guid.NewGuid(), new TranscriptMetadata("test", "1", "test"), speakers: speakers);
}

[TestClass]
public sealed class SpeakerPreviewSelectorTests
{
    [TestMethod]
    public void SelectsLongestContinuousIntervalForEachSpeaker()
    {
        var firstSpeaker = Fixtures.Id(701);
        var secondSpeaker = Fixtures.Id(702);
        var transcript = MakeTranscript(
            [new Speaker(id: firstSpeaker), new Speaker(id: secondSpeaker)],
            [
                new TranscriptSegment(10, 11, "short", speakerId: firstSpeaker),
                new TranscriptSegment(0, 2, "long", speakerId: firstSpeaker),
                new TranscriptSegment(2, 6, "long", speakerId: firstSpeaker),
                new TranscriptSegment(8, 9, "gap", speakerId: firstSpeaker),
                new TranscriptSegment(20, 23, "second", speakerId: secondSpeaker),
            ]);

        CollectionAssert.AreEqual(
            new[] { new SpeakerPreview(firstSpeaker, 0, 6), new SpeakerPreview(secondSpeaker, 20, 23) },
            SpeakerPreviewSelector.Previews(transcript).ToArray());
    }

    [TestMethod]
    public void CapsPreviewToTenSecondsWithoutLeavingKnownInterval()
    {
        var speakerId = Fixtures.Id(703);
        var transcript = MakeTranscript([new Speaker(id: speakerId)], [new TranscriptSegment(4, 30, "long segment", speakerId: speakerId)]);

        var preview = SpeakerPreviewSelector.Previews(transcript).Single();

        Assert.AreEqual(4, preview.StartTime);
        Assert.AreEqual(14, preview.EndTime);
        Assert.IsLessThanOrEqualTo(10, preview.EndTime - preview.StartTime);
    }

    [TestMethod]
    public void UsesCustomMaximumDuration()
    {
        var speakerId = Fixtures.Id(704);
        var transcript = MakeTranscript([new Speaker(id: speakerId)], [new TranscriptSegment(1, 8, "segment", speakerId: speakerId)]);

        var preview = SpeakerPreviewSelector.Previews(transcript, maxDuration: 3).Single();

        Assert.AreEqual(new SpeakerPreview(speakerId, 1, 4), preview);
    }

    [TestMethod]
    public void UsesWordEvidenceToTrimPreviewWithinSegmentBounds()
    {
        var speakerId = Fixtures.Id(705);
        var transcript = MakeTranscript(
            [new Speaker(id: speakerId)],
            [
                new TranscriptSegment(
                    0,
                    10,
                    "word-timed segment",
                    speakerId: speakerId,
                    words: new[] { new TranscriptWord(2, 3, "word"), new TranscriptWord(4, 6, "evidence") }),
            ]);

        var preview = SpeakerPreviewSelector.Previews(transcript).Single();

        Assert.AreEqual(new SpeakerPreview(speakerId, 2, 6), preview);
    }

    private static Transcript MakeTranscript(Speaker[] speakers, TranscriptSegment[] segments) =>
        new(Guid.NewGuid(), new TranscriptMetadata("test", "1", "test"), speakers: speakers, segments: segments);
}
