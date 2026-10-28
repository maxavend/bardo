using System.Text.Json;
using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Serialization;
using static Bardo.Tests.Fixtures;

namespace Bardo.Tests.Persistence;

/// <summary>
/// Reads a Library written by Bardo for macOS's own store (see
/// <c>windows/tools/macos-fixtures</c>), and writes it back the way macOS reads it.
/// </summary>
[TestClass]
public sealed class MacLibraryCompatibilityTests
{
    private TemporaryDirectory _root = null!;

    [TestInitialize]
    public void SetUp()
    {
        _root = new TemporaryDirectory("BardoMacLibrary");
        CopyMacLibrary(_root.Path);
    }

    [TestCleanup]
    public void TearDown() => _root.Dispose();

    [TestMethod]
    public async Task EveryManifestVersionLoads()
    {
        using var store = new RecordingStore(_root.Path);

        var snapshot = await store.LoadLibraryAsync();

        Assert.AreEqual(0, snapshot.Issues.Count, string.Join("; ", snapshot.Issues.Select(issue => issue.Message)));
        CollectionAssert.AreEqual(new[] { Id(1), Id(3), Id(2) }, snapshot.Recordings.Select(recording => recording.Id).ToArray(), "Newest first");
    }

    [TestMethod]
    public async Task CurrentManifestKeepsEverything()
    {
        using var store = new RecordingStore(_root.Path);

        var recording = await store.ReadAsync(Id(1));

        Assert.AreEqual("Reunión de diseño", recording.Title);
        Assert.AreEqual(1_761_650_000.123_457, BardoTime.ToSecondsSince1970(recording.CreatedAt), "Kept to the microsecond");
        Assert.AreEqual(187.5, recording.Duration);
        CollectionAssert.AreEquivalent(new[] { AudioSource.Microphone, AudioSource.SystemAudio }, recording.Sources.ToArray());
        Assert.AreEqual(ProcessingState.Completed, recording.ProcessingState);
        Assert.IsTrue(recording.SkipsSilences);

        var (microphone, system, mix) = (recording.AudioAssets[0], recording.AudioAssets[1], recording.AudioAssets[2]);
        Assert.AreEqual("m4a", microphone.FileExtension, "macOS lower-cases the extension too");
        Assert.AreEqual(AudioAssetRole.MicrophoneOriginal, microphone.Role);
        Assert.AreEqual(new AudioMetadata(187.5, "aac", 48_000, 2), system.Metadata);
        Assert.AreEqual(0.125, system.TimelineOffset);
        CollectionAssert.AreEqual(new[] { Id(11), Id(12) }, mix.DerivedFromAssetIds.ToArray());

        Assert.AreEqual("Decisión", recording.Notes.Moments[0].Title);
        Assert.AreEqual("Lanzar el jueves", recording.Notes.Moments[0].Note);
        CollectionAssert.AreEqual(new[] { "Contexto", "Cierre" }, recording.Notes.Sections.Select(section => section.Title).ToArray());
        Assert.AreEqual(Path.Combine(store.RecordingDirectoryPath(Id(1)), "audio", $"{Id(13).ToUuidString()}.m4a"),
            await store.ManagedAudioPathAsync(Id(1), Id(13)));
    }

    [TestMethod]
    public async Task OlderManifestsLoadWithTheirDefaults()
    {
        using var store = new RecordingStore(_root.Path);

        var first = await store.ReadAsync(Id(2));
        Assert.AreEqual(BardoTime.FromSecondsSince1970(1_700_000_000), first.CreatedAt);
        Assert.IsNull(first.Duration);
        Assert.AreEqual(0, first.AudioAssets.Count);
        Assert.IsTrue(first.Notes.IsEmpty);

        var second = await store.ReadAsync(Id(3));
        Assert.AreEqual(BardoTime.FromSecondsSince1970(1_700_000_100.25), second.CreatedAt);
        Assert.AreEqual(ProcessingState.Failed, second.ProcessingState);
        Assert.AreEqual(AudioAssetRole.SystemOriginal, second.AudioAssets[0].Role, "Version 2 infers the role from the sources");
    }

    [TestMethod]
    public async Task TranscriptKeepsEverything()
    {
        using var store = new TranscriptStore(_root.Path);

        var transcript = await store.ReadAsync(Id(1));

        Assert.IsNotNull(transcript);
        Assert.AreEqual("es", transcript.LanguageCode);
        CollectionAssert.AreEqual(new SpeakerRole?[] { SpeakerRole.LocalUser, SpeakerRole.Others, null }, transcript.Speakers.Select(speaker => speaker.Role).ToArray());
        Assert.AreEqual("Maxi", transcript.Speakers[0].Name);

        var first = transcript.Segments[0];
        Assert.AreEqual(Id(31), first.SpeakerId);
        Assert.AreEqual(TranscriptSource.Microphone, first.Source);
        Assert.AreEqual(0.98f, first.Words[0].Probability);
        Assert.IsNull(first.Words[1].Probability);
        Assert.AreEqual("Revisemos el estado vacío.", transcript.Segments[1].DisplayText);
        Assert.IsNull(transcript.Segments[2].SpeakerId);

        Assert.AreEqual(BardoTime.FromSecondsSince1970(1_761_650_200.5), transcript.Metadata.CreatedAt, "Seconds since 2001 in transcripts");
        Assert.AreEqual(new TranscriptionSelection(TranscriptionBackend.WhisperKit, TranscriptionSelection.LargeModelId), transcript.Metadata.Selection);
        Assert.AreEqual(TranscriptionTrackMode.PerTrack, transcript.Metadata.TrackMode);
        Assert.AreEqual(18.25, transcript.Metadata.ProcessingDuration);
        Assert.AreEqual("SpeakerKit", transcript.DiarizationMetadata?.Engine);
        Assert.AreEqual(BardoTime.FromSecondsSince1970(1_761_650_210), transcript.DiarizationMetadata?.CreatedAt);
    }

    [TestMethod]
    public async Task RewritingKeepsTheJsonMacOSWrote()
    {
        var manifestPath = Path.Combine(_root.Path, Id(1).ToUuidString(), RecordingStore.ManifestFileName);
        var transcriptPath = Path.Combine(_root.Path, Id(1).ToUuidString(), TranscriptStore.TranscriptFileName);
        var originalManifest = JsonDocument.Parse(File.ReadAllBytes(Fixtures.MacLibrary + "/" + Id(1).ToUuidString() + "/" + RecordingStore.ManifestFileName));
        var originalTranscript = JsonDocument.Parse(File.ReadAllBytes(Fixtures.MacLibrary + "/" + Id(1).ToUuidString() + "/" + TranscriptStore.TranscriptFileName));

        using (var recordings = new RecordingStore(_root.Path)) await recordings.UpdateAsync(await recordings.ReadAsync(Id(1)));
        using (var transcripts = new TranscriptStore(_root.Path)) await transcripts.SaveAsync((await transcripts.ReadAsync(Id(1)))!);

        using var manifest = JsonDocument.Parse(File.ReadAllBytes(manifestPath));
        using var transcript = JsonDocument.Parse(File.ReadAllBytes(transcriptPath));
        AssertSameJson(originalManifest.RootElement, manifest.RootElement, "manifest", ignoring: ["createdAtEpochSeconds", "createdAtEpochSecondsBitPattern"]);
        AssertSameJson(originalTranscript.RootElement, transcript.RootElement, "transcript", ignoring: []);
        Assert.AreEqual(
            originalManifest.RootElement.GetProperty("createdAtEpochSeconds").GetDouble(),
            manifest.RootElement.GetProperty("createdAtEpochSeconds").GetDouble(),
            1e-6,
            "The creation date moves by under a microsecond at most");
        originalManifest.Dispose();
        originalTranscript.Dispose();
    }

    /// <summary>Same keys and values, in any key order, with numbers compared as numbers.</summary>
    private static void AssertSameJson(JsonElement expected, JsonElement actual, string path, IReadOnlyCollection<string> ignoring)
    {
        Assert.AreEqual(expected.ValueKind, actual.ValueKind, path);
        switch (expected.ValueKind)
        {
            case JsonValueKind.Object:
                var expectedKeys = expected.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal).ToArray();
                var actualKeys = actual.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal).ToArray();
                CollectionAssert.AreEqual(expectedKeys, actualKeys, path);
                foreach (var property in expected.EnumerateObject().Where(property => !ignoring.Contains(property.Name)))
                {
                    AssertSameJson(property.Value, actual.GetProperty(property.Name), $"{path}.{property.Name}", ignoring);
                }
                break;
            case JsonValueKind.Array:
                Assert.AreEqual(expected.GetArrayLength(), actual.GetArrayLength(), path);
                for (var index = 0; index < expected.GetArrayLength(); index++)
                {
                    AssertSameJson(expected[index], actual[index], $"{path}[{index}]", ignoring);
                }
                break;
            case JsonValueKind.Number:
                Assert.AreEqual(expected.GetDouble(), actual.GetDouble(), path);
                break;
            default:
                Assert.AreEqual(expected.ToString(), actual.ToString(), path);
                break;
        }
    }
}
