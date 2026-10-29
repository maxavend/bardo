using System.ComponentModel;
using Bardo.Domain;
using Bardo.Library;
using Bardo.Persistence;
using Bardo.Serialization;
using Bardo.Settings;
using static Bardo.Tests.Fixtures;

namespace Bardo.Tests.Library;

/// <summary>The Library window's state, driven on the Library macOS wrote.</summary>
[TestClass]
public sealed class LibraryViewModelTests
{
    private TemporaryDirectory _root = null!;
    private string _library = null!;

    [TestInitialize]
    public void SetUp()
    {
        _root = new TemporaryDirectory("BardoLibraryViewModel");
        _library = Path.Combine(_root.Path, "Library");
        Directory.CreateDirectory(_library);
    }

    [TestCleanup]
    public void TearDown() => _root.Dispose();

    private void CopyMacLibrary() => Fixtures.CopyMacLibrary(_library);

    private async Task<LibraryViewModel> Loaded(IRecycleBin? recycleBin = null, IAudioMetadataReader? reader = null)
    {
        var model = new LibraryViewModel(_library, new PreferencesStore(_root.Path), recycleBin, reader);
        await model.LoadAsync();
        return model;
    }

    [TestMethod]
    public async Task AnEmptyLibrarySaysSoAndSelectsNothing()
    {
        using var model = await Loaded();

        Assert.IsTrue(model.IsLibraryEmpty);
        Assert.IsFalse(model.IsFilterEmpty);
        Assert.IsFalse(model.HasSelection);
        Assert.IsFalse(model.HasNoSelection, "No “select a conversation” when there is none");
    }

    [TestMethod]
    public async Task TheNewestConversationOpensWithItsTranscript()
    {
        CopyMacLibrary();
        using var model = await Loaded();

        Assert.HasCount(3, model.Rows);
        Assert.AreEqual(Id(1), model.Selected?.Id);
        Assert.AreEqual("Reunión de diseño", model.SelectedTitle);
        Assert.IsTrue(model.HasTranscript);
        Assert.AreEqual("Maxi", model.Blocks[0].Heading);
        Assert.AreEqual("0:01–0:03", model.Blocks[0].Time);
        Assert.AreEqual("Hola, partamos.", model.Blocks[0].Text);
        Assert.AreEqual("Revisemos el estado vacío.", model.Blocks[1].Text, "Edited text is what shows");
        Assert.AreEqual("0:10–0:12", model.Blocks[2].Heading, "Without a speaker, the time heads the block");
    }

    [TestMethod]
    public async Task AConversationWithoutTranscriptSaysSo()
    {
        CopyMacLibrary();
        using var model = await Loaded();

        model.Selected = model.Rows.Single(row => row.Id == Id(3));

        Assert.IsTrue(model.HasNoTranscript);
        Assert.IsFalse(model.HasTranscript);
        Assert.IsNull(model.SelectedTranscriptText());
    }

    [TestMethod]
    public async Task SearchAndSectionsNarrowTheListAndKeepTheSelection()
    {
        CopyMacLibrary();
        using var model = await Loaded();

        model.Query = "VACIO";
        CollectionAssert.AreEqual(new[] { Id(1) }, model.Rows.Select(row => row.Id).ToArray(), "Found in what was said, without the accent");
        Assert.AreEqual(Id(1), model.Selected?.Id);

        model.Query = "presupuesto";
        Assert.IsTrue(model.IsFilterEmpty);
        Assert.IsFalse(model.HasSelection);

        model.Query = "";
        model.Section = LibrarySection.Imported;
        Assert.IsTrue(model.IsFilterEmpty, "Nothing in the fixture was imported");
        model.Section = LibrarySection.Recorded;
        Assert.HasCount(3, model.Rows);
    }

    [TestMethod]
    public async Task ReloadingKeepsWhatWasSelected()
    {
        CopyMacLibrary();
        using var model = await Loaded();
        model.Selected = model.Rows.Single(row => row.Id == Id(2));

        await model.LoadAsync();

        Assert.AreEqual(Id(2), model.Selected?.Id);
    }

    [TestMethod]
    public async Task CopiedTextMatchesTheExport()
    {
        CopyMacLibrary();
        using var model = await Loaded();

        var text = model.SelectedTranscriptText();

        Assert.IsNotNull(text);
        StringAssert.StartsWith(text, "Reunión de diseño\n");
        StringAssert.Contains(text, "CONTEXTO · 0:00");
        StringAssert.Contains(text, "⚑ 0:43 · Decisión: Lanzar el jueves");
    }

    [TestMethod]
    public async Task UnreadableItemsAreCountedNotHidden()
    {
        CopyMacLibrary();
        var broken = Path.Combine(_library, Guid.NewGuid().ToUuidString());
        Directory.CreateDirectory(broken);
        File.WriteAllText(Path.Combine(broken, RecordingStore.ManifestFileName), "{ not json");
        File.WriteAllText(Path.Combine(_library, Id(1).ToUuidString(), TranscriptStore.TranscriptFileName), "{ not json");
        using var model = await Loaded();

        Assert.AreEqual(1, model.IssueCount);
        Assert.IsTrue(model.HasIssues);
        Assert.HasCount(3, model.Rows, "A broken transcript does not hide its recording");
        Assert.IsTrue(model.HasNoTranscript);
    }

    [TestMethod]
    public async Task ChangesAreAnnouncedToBindings()
    {
        CopyMacLibrary();
        using var model = await Loaded();
        var changed = new List<string?>();
        ((INotifyPropertyChanged)model).PropertyChanged += (_, args) => changed.Add(args.PropertyName);

        model.Selected = model.Rows.Single(row => row.Id == Id(3));

        CollectionAssert.IsSubsetOf(
            new[] { nameof(LibraryViewModel.Selected), nameof(LibraryViewModel.SelectedTitle), nameof(LibraryViewModel.HasTranscript), nameof(LibraryViewModel.HasNoTranscript) },
            changed);
    }
    [TestMethod]
    public async Task FavoritesAreKeptAndListedApart()
    {
        CopyMacLibrary();
        using (var model = await Loaded())
        {
            model.ToggleFavorite(Id(2));
            model.Section = LibrarySection.Favorites;
            CollectionAssert.AreEqual(new[] { Id(2) }, model.Rows.Select(row => row.Id).ToArray());
            Assert.IsTrue(model.Rows[0].IsFavorite);
        }

        using var reopened = await Loaded();
        reopened.Section = LibrarySection.Favorites;
        Assert.HasCount(1, reopened.Rows, "Favorites survive a restart");
    }

    [TestMethod]
    public async Task SortingIsRememberedAndApplied()
    {
        CopyMacLibrary();
        using (var model = await Loaded())
        {
            model.Sort = LibrarySort.Oldest;
            CollectionAssert.AreEqual(new[] { Id(2), Id(3), Id(1) }, model.Rows.Select(row => row.Id).ToArray());
            model.Sort = LibrarySort.Name;
            CollectionAssert.AreEqual(new[] { "Primera versión", "Reunión de diseño", "Segunda versión" }, model.Rows.Select(row => row.Title).ToArray());
        }

        using var reopened = await Loaded();
        Assert.AreEqual(LibrarySort.Name, reopened.Sort);
    }

    [TestMethod]
    public async Task RenamingSavesAndRejectsBlankTitles()
    {
        CopyMacLibrary();
        using var model = await Loaded();

        Assert.IsFalse(await model.RenameAsync(Id(1), "   "));
        Assert.IsTrue(model.Notice?.IsError);
        Assert.IsTrue(await model.RenameAsync(Id(1), "  Revisión final  "));

        Assert.AreEqual("Revisión final", model.SelectedTitle);
        using var store = new RecordingStore(_library);
        Assert.AreEqual("Revisión final", (await store.ReadAsync(Id(1))).Title);
    }

    [TestMethod]
    public async Task RecycledConversationsLeaveTheList()
    {
        CopyMacLibrary();
        var recycleBin = new MovingRecycleBin(Path.Combine(_root.Path, "Recycled"));
        using var model = await Loaded(recycleBin);

        Assert.IsTrue(await model.MoveToRecycleBinAsync(Id(1)));

        CollectionAssert.AreEqual(new[] { Id(3), Id(2) }, model.Rows.Select(row => row.Id).ToArray());
        Assert.HasCount(1, recycleBin.Recycled);
    }

    [TestMethod]
    public async Task ImportedAudioOpensAsAConversation()
    {
        var source = Path.Combine(_root.Path, "Entrevista con Ana.m4a");
        File.WriteAllText(source, "audio");
        using var model = await Loaded(reader: new FixedMetadataReader(new AudioMetadata(95, "AAC", 44_100, 2)));

        await model.ImportAsync([source, Path.Combine(_root.Path, "notas.txt")]);

        Assert.AreEqual("Entrevista con Ana", model.SelectedTitle);
        Assert.IsTrue(model.HasNoTranscript);
        Assert.IsTrue(model.Notice?.IsError, "The text file is reported");
        model.Section = LibrarySection.Imported;
        Assert.HasCount(1, model.Rows);
    }

    [TestMethod]
    public async Task TranscribingSavesTheTranscriptAndReportsProgress()
    {
        CopyMacLibrary();
        using var model = await Loaded();
        var transcriber = new FakeTranscriber();
        model.Transcriber = transcriber;
        model.Selected = model.Rows.Single(row => row.Id == Id(3));
        Assert.IsTrue(model.CanTranscribeSelected);

        var running = model.TranscribeAsync(Id(3));
        await transcriber.Started.Task;
        Assert.IsTrue(model.IsSelectedWorking);
        Assert.IsFalse(model.CanTranscribeSelected, "One job at a time");
        transcriber.Finish.SetResult();
        await running;

        Assert.IsFalse(model.IsWorking);
        Assert.AreEqual(Id(3), model.Selected?.Id);
        Assert.AreEqual("Hola desde Windows.", model.Blocks[0].Text);
        using var store = new RecordingStore(_library);
        Assert.AreEqual(ProcessingState.Completed, (await store.ReadAsync(Id(3))).ProcessingState);
    }

    [TestMethod]
    public async Task AFailedTranscriptionIsReportedAndMarked()
    {
        CopyMacLibrary();
        using var model = await Loaded();
        model.Transcriber = new FakeTranscriber(fail: true);

        await model.TranscribeAsync(Id(3));

        Assert.IsTrue(model.Notice?.IsError);
        using var store = new RecordingStore(_library);
        Assert.AreEqual(ProcessingState.Failed, (await store.ReadAsync(Id(3))).ProcessingState);
    }

    [TestMethod]
    public async Task ParticipantsCanBeNamedAndMerged()
    {
        CopyMacLibrary();
        using var model = await Loaded();
        Assert.HasCount(3, model.Speakers);
        var numbered = model.Speakers[2];
        var others = model.Speakers[1];

        Assert.IsTrue(await model.RenameSpeakerAsync(numbered.Id, " Ana "));
        Assert.AreEqual("Ana", model.Speakers[2].DisplayName);
        Assert.AreEqual("Ana", model.Blocks[1].Heading);

        Assert.IsTrue(await model.MergeSpeakersAsync(others.Id, numbered.Id));
        Assert.HasCount(2, model.Speakers);

        using var store = new TranscriptStore(_library);
        var saved = await store.ReadAsync(Id(1));
        Assert.AreEqual("Ana", saved!.Speakers[1].Name);
    }

    [TestMethod]
    public async Task PlaybackCanLeaveParticipantsOut()
    {
        CopyMacLibrary();
        using var model = await Loaded();
        Assert.IsTrue(model.CanChooseListened);
        Assert.IsNull(model.ListenedSpeakers);
        Assert.IsEmpty(model.PlaybackSkips(60));
        var kept = model.Speakers[0];

        foreach (var speaker in model.Speakers.Skip(1)) model.SetListened(speaker.Id, false);
        model.SetListened(kept.Id, false);

        CollectionAssert.AreEquivalent(new[] { kept.Id }, model.ListenedSpeakers!.ToArray(), "Someone is always heard");
        var transcript = model.SelectedTranscript!;
        var skips = model.PlaybackSkips(transcript.Segments.Max(segment => segment.EndTime) + 5);
        Assert.IsNotEmpty(skips);
        foreach (var segment in transcript.Segments.Where(segment => segment.SpeakerId == kept.Id))
        {
            Assert.IsFalse(skips.Any(skip => skip.Start < segment.EndTime && segment.StartTime < skip.End), "Their turns play");
        }

        // Merged into the one heard, the others are heard too: everyone plays again.
        foreach (var speaker in model.Speakers.Skip(1).ToList()) Assert.IsTrue(await model.MergeSpeakersAsync(speaker.Id, kept.Id));
        Assert.IsNull(model.ListenedSpeakers);
        Assert.IsFalse(model.CanChooseListened);
    }

    [TestMethod]
    public async Task SpeakerIdentificationReplacesTheTranscript()
    {
        CopyMacLibrary();
        using var model = await Loaded();
        model.SpeakerIdentifier = new FakeSpeakerIdentifier();
        Assert.IsTrue(model.CanIdentifySpeakers);

        await model.IdentifySpeakersAsync(Id(1));

        Assert.IsTrue(model.Blocks.All(block => block.Heading == "Identificado"));
    }

    private sealed class MovingRecycleBin(string folder) : IRecycleBin
    {
        public List<string> Recycled { get; } = [];

        public void Recycle(string path)
        {
            Directory.CreateDirectory(folder);
            Directory.Move(path, Path.Combine(folder, Path.GetFileName(path)));
            Recycled.Add(path);
        }
    }

    private sealed class FixedMetadataReader(AudioMetadata metadata) : IAudioMetadataReader
    {
        public AudioMetadata Read(string path) => metadata;
    }

    private sealed class FakeTranscriber(bool fail = false) : ITranscriber
    {
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Finish { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<Transcript> TranscribeAsync(Recording recording, IProgress<WorkProgress> progress, CancellationToken cancellationToken)
        {
            if (fail) throw new InvalidOperationException("Sin modelo");
            progress.Report(new WorkProgress(0.5));
            Started.SetResult();
            await Finish.Task;
            return new Transcript(recording.Id, Metadata(), segments: [new TranscriptSegment(0, 2, "Hola desde Windows.")]);
        }
    }

    private sealed class FakeSpeakerIdentifier : ISpeakerIdentifier
    {
        public Task<Transcript> IdentifySpeakersAsync(Recording recording, Transcript transcript, IProgress<WorkProgress> progress, CancellationToken cancellationToken)
        {
            var speaker = new Speaker(name: "Identificado");
            return Task.FromResult(transcript with
            {
                Speakers = [speaker],
                Segments = transcript.Segments.Select(segment => segment with { SpeakerId = speaker.Id }).ToEquatableArray(),
            });
        }
    }
}
