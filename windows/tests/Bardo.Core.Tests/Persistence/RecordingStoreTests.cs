using System.Text.Json;
using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Serialization;
using static Bardo.Tests.Fixtures;

namespace Bardo.Tests.Persistence;

[TestClass]
public sealed class RecordingStoreTests
{
    private TemporaryDirectory _root = null!;

    [TestInitialize]
    public void SetUp() => _root = new TemporaryDirectory();

    [TestCleanup]
    public void TearDown() => _root.Dispose();

    private string ManifestPath(Guid id) => Path.Combine(_root.Path, id.ToUuidString(), RecordingStore.ManifestFileName);

    private static Recording MakeRecording(Guid id, string title, DateTimeOffset? createdAt = null, double? duration = 125.5) =>
        new(title, [AudioSource.Microphone, AudioSource.SystemAudio],
            createdAt ?? BardoTime.FromSecondsSince1970(1_700_000_000), duration, ProcessingState.Pending, id: id);

    [TestMethod]
    public async Task SaveAndReadPreserveRecordingAndCurrentSchemaVersion()
    {
        var id = Id(101);
        var recording = MakeRecording(id, "Persisted sync", BardoTime.FromSecondsSince1970(1_700_000_000.123_456));
        using var store = new RecordingStore(_root.Path);

        await store.SaveAsync(recording);
        var loaded = await store.ReadAsync(id);

        Assert.AreEqual(recording, loaded);
        using var json = JsonDocument.Parse(File.ReadAllBytes(ManifestPath(id)));
        Assert.AreEqual(3, json.RootElement.GetProperty("schemaVersion").GetInt32());
        Assert.AreEqual(1_700_000_000.123_456, json.RootElement.GetProperty("createdAtEpochSeconds").GetDouble());
    }

    [TestMethod]
    public async Task CurrentSchemaPreservesArbitraryCreatedAt()
    {
        var recording = MakeRecording(Guid.NewGuid(), "Arbitrary timestamp", DateTimeOffset.UtcNow);
        using (var store = new RecordingStore(_root.Path)) await store.SaveAsync(recording);

        using var restarted = new RecordingStore(_root.Path);
        var loaded = await restarted.ReadAsync(recording.Id);

        Assert.AreEqual(recording.CreatedAt, loaded.CreatedAt);
        Assert.AreEqual(recording, loaded);
    }

    [TestMethod]
    public async Task MultipleRecordingsCoexistAndFreshStoreRebuildsFromDisk()
    {
        var first = MakeRecording(Id(111), "Older", BardoTime.FromSecondsSince1970(1_700_000_000));
        var second = MakeRecording(Id(112), "Newer", BardoTime.FromSecondsSince1970(1_700_000_100));
        using (var store = new RecordingStore(_root.Path))
        {
            await store.SaveAsync(first);
            await store.SaveAsync(second);
        }

        using var restarted = new RecordingStore(_root.Path);
        var snapshot = await restarted.LoadLibraryAsync();

        CollectionAssert.AreEqual(new[] { second, first }, snapshot.Recordings.ToArray());
        Assert.AreEqual(0, snapshot.Issues.Count);
    }

    [TestMethod]
    public async Task UpdateAndDeleteHaveExplicitSemantics()
    {
        var recording = MakeRecording(Id(121), "Original");
        using var store = new RecordingStore(_root.Path);

        await store.SaveAsync(recording);
        recording = recording with { Title = "Updated", ProcessingState = ProcessingState.Completed };
        await store.UpdateAsync(recording);
        Assert.AreEqual(recording, await store.ReadAsync(recording.Id));

        await store.DeleteAsync(recording.Id);
        var error = await Assert.ThrowsExactlyAsync<RecordingStoreException>(() => store.ReadAsync(recording.Id));
        Assert.AreEqual(RecordingStoreErrorKind.RecordingNotFound, error.Kind);
        Assert.AreEqual(recording.Id, error.RecordingId);
    }

    [TestMethod]
    public async Task UpdatingAMissingRecordingFails()
    {
        using var store = new RecordingStore(_root.Path);

        var error = await Assert.ThrowsExactlyAsync<RecordingStoreException>(() => store.UpdateAsync(MakeRecording(Id(122), "Ghost")));

        Assert.AreEqual(RecordingStoreErrorKind.RecordingNotFound, error.Kind);
    }

    [TestMethod]
    public async Task ImportPublishesAudioAndReplacementSwapsItsFile()
    {
        using var store = new RecordingStore(_root.Path);
        var source = Path.Combine(_root.Path, "original.wav");
        await File.WriteAllBytesAsync(source, "RIFF-original"u8.ToArray());
        var original = new AudioAsset("Recording.wav", "wav", new AudioMetadata(2, "lpcm", 48_000, 1), AudioAssetRole.MicrophoneOriginal);
        var recording = new Recording("Compress", [AudioSource.Microphone], duration: 2, audioAssets: [original]);
        await store.ImportRecordingAsync(recording, original, source);
        Assert.IsTrue(File.Exists(source), "Importing copies unless ownership is transferred");
        var oldPath = await store.ManagedAudioPathAsync(recording.Id, original.Id);

        var compact = Path.Combine(_root.Path, "compact.m4a");
        await File.WriteAllBytesAsync(compact, "compact"u8.ToArray());
        var replacement = new AudioAsset("Recording.m4a", "m4a", new AudioMetadata(2, "aac", 24_000, 1), AudioAssetRole.MicrophoneOriginal, id: original.Id);

        var updated = await store.ReplaceAudioAsync(recording.Id, [(replacement, compact)]);

        CollectionAssert.AreEqual(new[] { replacement }, updated.AudioAssets.ToArray());
        CollectionAssert.AreEqual(new[] { replacement }, (await store.ReadAsync(recording.Id)).AudioAssets.ToArray());
        var newPath = await store.ManagedAudioPathAsync(recording.Id, original.Id);
        Assert.AreEqual(".m4a", Path.GetExtension(newPath));
        Assert.IsFalse(File.Exists(oldPath), "The old file goes once the manifest points at the new one");
        CollectionAssert.AreEqual("compact"u8.ToArray(), await File.ReadAllBytesAsync(newPath));
    }

    [TestMethod]
    public async Task ImportRejectsAMismatchedSetOfFiles()
    {
        using var store = new RecordingStore(_root.Path);
        var asset = new AudioAsset("a.m4a", "m4a", new AudioMetadata(1, "aac", 48_000, 2));
        var recording = new Recording("Mismatch", [AudioSource.ImportedFile], audioAssets: [asset]);

        var error = await Assert.ThrowsExactlyAsync<RecordingStoreException>(() =>
            store.ImportRecordingAsync(recording, new Dictionary<Guid, string>()));

        Assert.AreEqual(RecordingStoreErrorKind.AudioAssetFileSetMismatch, error.Kind);
        Assert.IsFalse(Directory.Exists(store.RecordingDirectoryPath(recording.Id)));
    }

    [TestMethod]
    public async Task FailedTransferReturnsMovedAudioToItsSource()
    {
        using var store = new RecordingStore(_root.Path);
        var metadata = new AudioMetadata(1, "aac", 48_000, 2);
        var first = new AudioAsset("first.m4a", "m4a", metadata);
        var second = new AudioAsset("second.m4a", "m4a", metadata);
        var firstSource = Path.Combine(_root.Path, "first.m4a");
        await File.WriteAllBytesAsync(firstSource, "first"u8.ToArray());
        var missingSource = Path.Combine(_root.Path, "missing.m4a");
        var recording = new Recording("Interrupted", [AudioSource.ImportedFile], audioAssets: [first, second]);

        await Assert.ThrowsExactlyAsync<RecordingStoreException>(() => store.ImportRecordingAsync(
            recording,
            new Dictionary<Guid, string> { [first.Id] = firstSource, [second.Id] = missingSource },
            transferringOwnership: true));

        Assert.IsTrue(File.Exists(firstSource), "Moved audio goes back where it came from");
        Assert.IsFalse(Directory.Exists(store.RecordingDirectoryPath(recording.Id)));
    }

    [TestMethod]
    public async Task IncompletePublicationIsReclaimedIntoStaging()
    {
        using var store = new RecordingStore(_root.Path);
        var recordingId = Guid.NewGuid();
        var assetId = Guid.NewGuid();
        var audio = Path.Combine(store.RecordingDirectoryPath(recordingId), RecordingStore.AudioDirectoryName);
        Directory.CreateDirectory(audio);
        await File.WriteAllBytesAsync(Path.Combine(audio, $".audio-{assetId.ToUuidString()}.tmp"), "caff...."u8.ToArray());
        var staging = Path.Combine(_root.Path, "staging");
        Directory.CreateDirectory(staging);

        Assert.IsTrue(await store.ReclaimIncompletePublicationAsync(recordingId, staging));

        Assert.IsTrue(File.Exists(Path.Combine(staging, $"{assetId.ToUuidString()}.caf")), "The container is recognised from its header");
        Assert.IsFalse(Directory.Exists(store.RecordingDirectoryPath(recordingId)));
    }

    [TestMethod]
    public void RecordingDirectoryIsInsideStoreRoot()
    {
        using var store = new RecordingStore(_root.Path);
        var id = Guid.NewGuid();

        var directory = store.RecordingDirectoryPath(id);

        Assert.AreEqual(Path.GetFullPath(_root.Path), Path.GetDirectoryName(Path.GetFullPath(directory)));
        Assert.AreEqual(id.ToUuidString(), Path.GetFileName(directory));
    }

    [TestMethod]
    public async Task EncodingFailureDoesNotReplacePreviouslyValidManifest()
    {
        var recording = MakeRecording(Id(131), "Stable", duration: 42);
        using var store = new RecordingStore(_root.Path);
        await store.SaveAsync(recording);

        await Assert.ThrowsExactlyAsync<RecordingStoreException>(() =>
            store.SaveAsync(recording with { Title = "Should not persist", Duration = double.NaN }));

        using var restarted = new RecordingStore(_root.Path);
        var loaded = await restarted.ReadAsync(recording.Id);
        Assert.AreEqual("Stable", loaded.Title);
        Assert.AreEqual(42, loaded.Duration);
    }

    [TestMethod]
    public async Task NotesAndSilenceSkippingArePersistedOnlyWhenPresent()
    {
        using var store = new RecordingStore(_root.Path);
        var plain = MakeRecording(Id(141), "Plain");
        await store.SaveAsync(plain);
        var plainJson = await File.ReadAllTextAsync(ManifestPath(plain.Id));
        Assert.IsFalse(plainJson.Contains("notes", StringComparison.Ordinal));
        Assert.IsFalse(plainJson.Contains("skipsSilences", StringComparison.Ordinal));

        var annotated = MakeRecording(Id(142), "Annotated") with
        {
            Notes = RecordingNotes.Empty.AddingMoment(5, "Idea", null).Notes,
            SkipsSilences = true,
        };
        await store.SaveAsync(annotated);
        Assert.AreEqual(annotated, await store.ReadAsync(annotated.Id));
    }

    [TestMethod]
    public async Task RecycledRecordingsGoThroughTheRecycleBin()
    {
        var recycleBin = new RecordingRecycleBin();
        using var store = new RecordingStore(_root.Path, recycleBin);
        var recording = MakeRecording(Id(151), "Old");
        await store.SaveAsync(recording);

        await store.MoveToRecycleBinAsync(recording.Id);

        CollectionAssert.AreEqual(new[] { store.RecordingDirectoryPath(recording.Id) }, recycleBin.Recycled);
    }

    private sealed class RecordingRecycleBin : IRecycleBin
    {
        public List<string> Recycled { get; } = [];

        public void Recycle(string path) => Recycled.Add(path);
    }
}
