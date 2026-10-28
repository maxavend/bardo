using System.Text.Json;
using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Serialization;

namespace Bardo.Tests.Persistence;

[TestClass]
public sealed class TranscriptStoreTests
{
    private TemporaryDirectory _root = null!;

    [TestInitialize]
    public void SetUp() => _root = new TemporaryDirectory("BardoTranscriptTests");

    [TestCleanup]
    public void TearDown() => _root.Dispose();

    private string TranscriptPath(Guid recordingId) =>
        Path.Combine(_root.Path, recordingId.ToUuidString(), TranscriptStore.TranscriptFileName);

    private async Task<Recording> SavedRecording(string title, AudioSource source)
    {
        var recording = new Recording(title, [source]);
        using var store = new RecordingStore(_root.Path);
        await store.SaveAsync(recording);
        return recording;
    }

    private static Transcript MakeTranscript(Guid recordingId) => new(
        recordingId,
        new TranscriptMetadata("WhisperKit", "1.0.0", "test-model", createdAt: BardoTime.FromSecondsSince1970(1_700_000_000)),
        languageCode: "en",
        segments:
        [
            new TranscriptSegment(0, 1, "Hello world.", words:
            [
                new TranscriptWord(0, 0.4, "Hello", 0.98f),
                new TranscriptWord(0.5, 1, "world.", 0.95f),
            ]),
        ]);

    [TestMethod]
    public async Task TranscriptRoundTripSurvivesFreshStoreInstance()
    {
        var recording = await SavedRecording("Transcript", AudioSource.ImportedFile);
        var transcript = MakeTranscript(recording.Id);
        using (var store = new TranscriptStore(_root.Path)) await store.SaveAsync(transcript);

        using var restarted = new TranscriptStore(_root.Path);
        var loaded = await restarted.ReadAsync(recording.Id);

        Assert.AreEqual(transcript, loaded);
        using var json = JsonDocument.Parse(File.ReadAllBytes(TranscriptPath(recording.Id)));
        Assert.AreEqual(1, json.RootElement.GetProperty("schemaVersion").GetInt32());
    }

    [TestMethod]
    public async Task MissingTranscriptReadsAsNone()
    {
        var recording = await SavedRecording("Awaiting", AudioSource.Microphone);
        using var store = new TranscriptStore(_root.Path);

        Assert.IsNull(await store.ReadAsync(recording.Id));
    }

    [TestMethod]
    public async Task SavingForAMissingRecordingFails()
    {
        using var store = new TranscriptStore(_root.Path);

        var error = await Assert.ThrowsExactlyAsync<TranscriptStoreException>(() => store.SaveAsync(MakeTranscript(Guid.NewGuid())));

        Assert.AreEqual(TranscriptStoreErrorKind.RecordingNotFound, error.Kind);
    }

    [TestMethod]
    public async Task CorruptTranscriptDoesNotPreventRecordingLibraryRecovery()
    {
        var recording = await SavedRecording("Audio remains", AudioSource.Microphone);
        File.WriteAllText(TranscriptPath(recording.Id), "{ definitely-not-json");

        using (var recordings = new RecordingStore(_root.Path))
        {
            var snapshot = await recordings.LoadLibraryAsync();
            CollectionAssert.AreEqual(new[] { recording.Id }, snapshot.Recordings.Select(item => item.Id).ToArray());
        }

        using var store = new TranscriptStore(_root.Path);
        var error = await Assert.ThrowsExactlyAsync<TranscriptStoreException>(() => store.ReadAsync(recording.Id));
        Assert.AreEqual(TranscriptStoreErrorKind.InvalidTranscript, error.Kind);
    }

    [TestMethod]
    public async Task NewerTranscriptSchemaIsReportedNotRead()
    {
        var recording = await SavedRecording("Future", AudioSource.Microphone);
        File.WriteAllText(TranscriptPath(recording.Id), """{"schemaVersion":2}""");
        using var store = new TranscriptStore(_root.Path);

        var error = await Assert.ThrowsExactlyAsync<TranscriptStoreException>(() => store.ReadAsync(recording.Id));

        Assert.AreEqual(TranscriptStoreErrorKind.UnsupportedSchemaVersion, error.Kind);
        Assert.AreEqual(2, error.SchemaVersion);
    }

    [TestMethod]
    public async Task FailedTranscriptEncodingDoesNotReplacePreviouslyValidTranscript()
    {
        var recording = await SavedRecording("Stable transcript", AudioSource.ImportedFile);
        using var store = new TranscriptStore(_root.Path);
        var valid = MakeTranscript(recording.Id);
        await store.SaveAsync(valid);

        var invalid = valid with
        {
            Segments = [valid.Segments[0] with { Words = [new TranscriptWord(0, 0.2, "Hello", float.NaN)] }],
        };
        await Assert.ThrowsExactlyAsync<TranscriptStoreException>(() => store.SaveAsync(invalid));

        using var restarted = new TranscriptStore(_root.Path);
        Assert.AreEqual(valid, await restarted.ReadAsync(recording.Id));
    }

    [TestMethod]
    public async Task TemporaryTranscriptResidueIsPreservedAndDiscoverable()
    {
        var recording = await SavedRecording("Interrupted", AudioSource.ImportedFile);
        var residue = Path.Combine(_root.Path, recording.Id.ToUuidString(), ".transcript-interrupted.tmp");
        File.WriteAllText(residue, "partial");

        using (var store = new TranscriptStore(_root.Path))
        {
            var artifacts = await store.TemporaryArtifactsAsync(recording.Id);
            CollectionAssert.AreEqual(new[] { Path.GetFileName(residue) }, artifacts.Select(Path.GetFileName).ToArray());
        }

        using var recordings = new RecordingStore(_root.Path);
        var snapshot = await recordings.LoadLibraryAsync();
        CollectionAssert.AreEqual(new[] { recording.Id }, snapshot.Recordings.Select(item => item.Id).ToArray());
        Assert.IsTrue(File.Exists(residue));
    }
}
