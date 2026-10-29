using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Serialization;
using static Bardo.Tests.Fixtures;

namespace Bardo.Tests.Persistence;

[TestClass]
public sealed class RecordingStoreRecoveryTests
{
    private TemporaryDirectory _root = null!;

    [TestInitialize]
    public void SetUp() => _root = new TemporaryDirectory("BardoRecoveryTests");

    [TestCleanup]
    public void TearDown() => _root.Dispose();

    private string RecordingDirectory(Guid id) => Path.Combine(_root.Path, id.ToUuidString());

    private string ManifestPath(Guid id) => Path.Combine(RecordingDirectory(id), RecordingStore.ManifestFileName);

    private void WriteRawManifest(string json, Guid id)
    {
        Directory.CreateDirectory(RecordingDirectory(id));
        File.WriteAllText(ManifestPath(id), json);
    }

    private static Recording MakeRecording(Guid id, string title, double createdAt) =>
        new(title, [], BardoTime.FromSecondsSince1970(createdAt), id: id);

    private async Task<LibrarySnapshot> LoadLibrary()
    {
        using var store = new RecordingStore(_root.Path);
        return await store.LoadLibraryAsync();
    }

    [TestMethod]
    public async Task CorruptRecordingDoesNotHideHealthyNeighbors()
    {
        var a = MakeRecording(Id(301), "A", 1_700_000_300);
        var bId = Id(302);
        var c = MakeRecording(Id(303), "C", 1_700_000_500);
        using (var store = new RecordingStore(_root.Path))
        {
            await store.SaveAsync(a);
            await store.SaveAsync(c);
        }
        WriteRawManifest("{ definitely-not-json", bId);

        var snapshot = await LoadLibrary();

        CollectionAssert.AreEqual(new[] { c, a }, snapshot.Recordings.ToArray());
        Assert.AreEqual(1, snapshot.Issues.Count);
        Assert.AreEqual(RecordingStoreIssue.IssueKind.CorruptManifest, snapshot.Issues[0].Kind);
        Assert.AreEqual(bId, snapshot.Issues[0].RecordingId);
        Assert.IsTrue(File.Exists(ManifestPath(bId)));
    }

    [TestMethod]
    public async Task IncompleteManifestIsReportedAndPreserved()
    {
        var id = Id(311);
        WriteRawManifest($$"""{"schemaVersion":1,"id":"{{id.ToUuidString()}}"}""", id);

        var snapshot = await LoadLibrary();

        Assert.AreEqual(0, snapshot.Recordings.Count);
        CollectionAssert.AreEqual(new[] { RecordingStoreIssue.IssueKind.CorruptManifest }, snapshot.Issues.Select(issue => issue.Kind).ToArray());
        Assert.IsTrue(File.Exists(ManifestPath(id)));
    }

    [TestMethod]
    public async Task UnsupportedSchemaIsDetectedWithoutMigrationOrDeletion()
    {
        var id = Id(321);
        WriteRawManifest("""{"schemaVersion":99}""", id);

        var snapshot = await LoadLibrary();

        Assert.AreEqual(0, snapshot.Recordings.Count);
        CollectionAssert.AreEqual(new[] { RecordingStoreIssue.IssueKind.UnsupportedSchemaVersion }, snapshot.Issues.Select(issue => issue.Kind).ToArray());
        Assert.IsTrue(File.Exists(ManifestPath(id)));
    }

    [TestMethod]
    public async Task TemporaryWriteResidueDoesNotReplaceValidManifest()
    {
        var recording = MakeRecording(Id(331), "Valid", 1_700_000_600);
        using (var store = new RecordingStore(_root.Path)) await store.SaveAsync(recording);
        var temporary = Path.Combine(RecordingDirectory(recording.Id), ".manifest-interrupted.tmp");
        File.WriteAllText(temporary, "partial");

        var snapshot = await LoadLibrary();

        CollectionAssert.AreEqual(new[] { recording }, snapshot.Recordings.ToArray());
        CollectionAssert.AreEqual(new[] { RecordingStoreIssue.IssueKind.TemporaryArtifact }, snapshot.Issues.Select(issue => issue.Kind).ToArray());
        Assert.IsTrue(File.Exists(temporary));
    }

    [TestMethod]
    public async Task TemporaryOnlyRecordingIsDetectedAsIncompleteAndPreserved()
    {
        var id = Id(341);
        Directory.CreateDirectory(RecordingDirectory(id));
        var temporary = Path.Combine(RecordingDirectory(id), ".manifest-interrupted.tmp");
        File.WriteAllText(temporary, "partial");

        var snapshot = await LoadLibrary();

        Assert.AreEqual(0, snapshot.Recordings.Count);
        CollectionAssert.AreEquivalent(
            new[] { RecordingStoreIssue.IssueKind.TemporaryArtifact, RecordingStoreIssue.IssueKind.MissingManifest },
            snapshot.Issues.Select(issue => issue.Kind).ToArray());
        Assert.IsTrue(File.Exists(temporary));
    }

    [TestMethod]
    public async Task RecordingWithoutTranscriptIsAValidPersistedState()
    {
        var recording = MakeRecording(Id(351), "Awaiting transcription", 1_700_000_700);
        using (var store = new RecordingStore(_root.Path)) await store.SaveAsync(recording);

        using var restarted = new RecordingStore(_root.Path);
        var loaded = await restarted.ReadAsync(recording.Id);

        Assert.AreEqual(recording, loaded);
        Assert.AreEqual(ProcessingState.Pending, loaded.ProcessingState);
    }

    [TestMethod]
    public async Task UnexpectedEntriesAndMissingAudioAreReportedNotRemoved()
    {
        File.WriteAllText(Path.Combine(_root.Path, "notes.txt"), "mine");
        var asset = new AudioAsset("a.m4a", "m4a", new AudioMetadata(1, "aac", 48_000, 2), AudioAssetRole.ConversationMix);
        var recording = new Recording("Sin audio", [AudioSource.ImportedFile], audioAssets: [asset]);
        using (var store = new RecordingStore(_root.Path)) await store.SaveAsync(recording);

        var snapshot = await LoadLibrary();

        CollectionAssert.AreEquivalent(
            new[] { RecordingStoreIssue.IssueKind.UnexpectedEntry, RecordingStoreIssue.IssueKind.MissingDerivedAudioFile },
            snapshot.Issues.Select(issue => issue.Kind).ToArray());
        Assert.IsTrue(File.Exists(Path.Combine(_root.Path, "notes.txt")));
    }

    [TestMethod]
    public void IssuePathsNeverLeaveTheLibrary()
    {
        using var store = new RecordingStore(_root.Path);

        foreach (var name in new[] { "..", ".", "", "../outside", @"..\outside" })
        {
            Assert.IsNull(store.ItemPath(new RecordingStoreIssue(RecordingStoreIssue.IssueKind.UnexpectedEntry, null, name, "")), name);
        }
    }
}
