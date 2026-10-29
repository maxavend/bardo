using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Serialization;
using static Bardo.Tests.Fixtures;

namespace Bardo.Tests.Domain;

[TestClass]
public sealed class DomainModelTests
{
    [TestMethod]
    public void TranscriptRoundTripsThroughJson()
    {
        var speaker = new Speaker(name: "Maxi", id: Id(2));
        var segment = new TranscriptSegment(3.25, 7.5, "Hola, esto es Bardo.", speakerId: speaker.Id, id: Id(3));
        var transcript = new Transcript(
            Id(1),
            new TranscriptMetadata("WhisperKit", "1.0.0", "fixture",
                createdAt: BardoTime.FromSecondsSince1970(1_700_000_100), processingDuration: 12.75),
            languageCode: "es",
            speakers: [speaker],
            segments: [segment]);

        var decoded = BardoJson.Deserialize<Transcript>(BardoJson.Serialize(transcript));

        Assert.AreEqual(transcript, decoded);
        Assert.AreEqual(12.75, decoded.Metadata.ProcessingDuration);
    }

    [TestMethod]
    public void LegacyTranscriptMetadataWithoutProcessingDurationStillDecodes()
    {
        const string json = """
            {
              "engine": "WhisperKit",
              "engineVersion": "1.0.0",
              "modelID": "fixture",
              "createdAt": 721692800
            }
            """;

        var decoded = BardoJson.Deserialize<TranscriptMetadata>(System.Text.Encoding.UTF8.GetBytes(json));

        Assert.IsNull(decoded.ProcessingDuration);
        Assert.AreEqual(new DateTimeOffset(2023, 11, 14, 22, 13, 20, TimeSpan.Zero), decoded.CreatedAt, "Seconds since 2001, as Swift writes them");
    }

    [TestMethod]
    public void MetadataWithoutCreationDateIsInvalid()
    {
        const string json = """{ "engine": "WhisperKit", "engineVersion": "1.0.0", "modelID": "fixture" }""";

        Assert.ThrowsExactly<System.Text.Json.JsonException>(() =>
            BardoJson.Deserialize<TranscriptMetadata>(System.Text.Encoding.UTF8.GetBytes(json)));
    }

    [TestMethod]
    public void SelectionReadsLikeTheMacApp()
    {
        static TranscriptionSelection Read(string json) =>
            BardoJson.Deserialize<TranscriptionSelection>(System.Text.Encoding.UTF8.GetBytes(json));

        Assert.AreEqual(new TranscriptionSelection(), Read("{}"), "Before there was a choice, it was Turbo");
        Assert.AreEqual(new TranscriptionSelection(TranscriptionBackend.WhisperKit, TranscriptionSelection.LargeModelId),
            Read("""{ "backend": "whisperKit", "modelID": "large-v3" }"""));
        Assert.AreEqual(new TranscriptionSelection(TranscriptionBackend.AppleSpeech, "apple"),
            Read("""{ "backend": "appleSpeech" }"""));
        Assert.AreEqual(new TranscriptionSelection(), Read("""{ "backend": "somethingNew", "modelID": "x" }"""));
    }

    [TestMethod]
    public void UuidsAreWrittenUpperCaseAndOptionalsLeftOut()
    {
        var json = System.Text.Encoding.UTF8.GetString(BardoJson.Serialize(new Speaker(id: Guid.Parse("e621e1f8-c36c-495a-93fc-0c247a3e6e5f"))));

        StringAssert.Contains(json, "\"E621E1F8-C36C-495A-93FC-0C247A3E6E5F\"");
        Assert.IsFalse(json.Contains("name", StringComparison.Ordinal));
        Assert.IsFalse(json.Contains("null", StringComparison.Ordinal));
    }

    [TestMethod]
    public void ManualChangeFlagsDistinguishTextAndSpeakerNames()
    {
        var speakerId = Id(799);
        var untouched = new Transcript(Id(700), Metadata(), speakers: [new Speaker(id: speakerId)],
            segments: [new TranscriptSegment(0, 1, "Original")]);
        Assert.IsFalse(untouched.HasManualTextEdits);
        Assert.IsFalse(untouched.HasNamedSpeakers);
        Assert.IsFalse(untouched.HasManualChanges);

        var textEdited = untouched with { Segments = [new TranscriptSegment(0, 1, "Original", editedText: "Corrected")] };
        Assert.IsTrue(textEdited.HasManualTextEdits);
        Assert.IsFalse(textEdited.HasNamedSpeakers);
        Assert.IsTrue(textEdited.HasManualChanges);

        var named = untouched with { Speakers = [new Speaker(name: "  Maxi  ", id: speakerId)] };
        Assert.IsFalse(named.HasManualTextEdits);
        Assert.IsTrue(named.HasNamedSpeakers);
        Assert.IsTrue(named.HasManualChanges);
    }

    [TestMethod]
    public void SegmentWithoutEditedTextUsesOriginalText()
    {
        var transcript = new Transcript(Id(701), Metadata(BardoTime.FromSecondsSince1970(1_700_007_001)), languageCode: "en",
            segments: [new TranscriptSegment(1, 3, "Original transcript", id: Id(702))]);
        var json = System.Text.Encoding.UTF8.GetString(BardoJson.Serialize(TranscriptDocumentV1.For(transcript)));
        Assert.IsFalse(json.Contains("editedText", StringComparison.Ordinal));

        var decoded = BardoJson.Deserialize<TranscriptDocumentV1>(System.Text.Encoding.UTF8.GetBytes(json)).Transcript;

        Assert.AreEqual("Original transcript", decoded.Segments[0].DisplayText);
        Assert.AreEqual("Original transcript", decoded.Text);
    }

    [TestMethod]
    public void AssetsNormalizeExtensionAndOffset()
    {
        var asset = new AudioAsset("a.M4A", "M4A", new AudioMetadata(1, "aac", 48_000, 2), timelineOffset: double.NaN);

        Assert.AreEqual("m4a", asset.FileExtension);
        Assert.AreEqual(0, asset.TimelineOffset);
    }

    [TestMethod]
    public void PlaybackPrefersTheMixThenOriginals()
    {
        var metadata = new AudioMetadata(1, "aac", 48_000, 2);
        var microphone = new AudioAsset("m", "m4a", metadata, AudioAssetRole.MicrophoneOriginal);
        var system = new AudioAsset("s", "m4a", metadata, AudioAssetRole.SystemOriginal);
        var mix = new AudioAsset("x", "m4a", metadata, AudioAssetRole.ConversationMix);
        var recording = new Recording("Orden", [AudioSource.Microphone], audioAssets: [microphone, system, mix]);

        CollectionAssert.AreEqual(new[] { mix, system, microphone }, recording.PlaybackAudioAssets.ToArray());
    }

    [TestMethod]
    public void DatesSurviveBeingWrittenAndReadBack()
    {
        var now = BardoTime.Now;

        Assert.AreEqual(now, BardoTime.FromSecondsSince1970(BardoTime.ToSecondsSince1970(now)));
        Assert.AreEqual(now, BardoTime.FromSecondsSinceReferenceDate(BardoTime.ToSecondsSinceReferenceDate(now)));
    }
}
