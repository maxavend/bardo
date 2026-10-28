using System.ComponentModel;
using Bardo.Library;
using Bardo.Persistence;
using Bardo.Serialization;
using static Bardo.Tests.Fixtures;

namespace Bardo.Tests.Library;

/// <summary>The Library window's state, driven on the Library macOS wrote.</summary>
[TestClass]
public sealed class LibraryViewModelTests
{
    private TemporaryDirectory _root = null!;

    [TestInitialize]
    public void SetUp() => _root = new TemporaryDirectory("BardoLibraryViewModel");

    [TestCleanup]
    public void TearDown() => _root.Dispose();

    private async Task<LibraryViewModel> Loaded()
    {
        var model = new LibraryViewModel(_root.Path);
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
        CopyMacLibrary(_root.Path);
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
        CopyMacLibrary(_root.Path);
        using var model = await Loaded();

        model.Selected = model.Rows.Single(row => row.Id == Id(3));

        Assert.IsTrue(model.HasNoTranscript);
        Assert.IsFalse(model.HasTranscript);
        Assert.IsNull(model.SelectedTranscriptText());
    }

    [TestMethod]
    public async Task SearchAndSectionsNarrowTheListAndKeepTheSelection()
    {
        CopyMacLibrary(_root.Path);
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
        CopyMacLibrary(_root.Path);
        using var model = await Loaded();
        model.Selected = model.Rows.Single(row => row.Id == Id(2));

        await model.LoadAsync();

        Assert.AreEqual(Id(2), model.Selected?.Id);
    }

    [TestMethod]
    public async Task CopiedTextMatchesTheExport()
    {
        CopyMacLibrary(_root.Path);
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
        CopyMacLibrary(_root.Path);
        var broken = Path.Combine(_root.Path, Guid.NewGuid().ToUuidString());
        Directory.CreateDirectory(broken);
        File.WriteAllText(Path.Combine(broken, RecordingStore.ManifestFileName), "{ not json");
        File.WriteAllText(Path.Combine(_root.Path, Id(1).ToUuidString(), TranscriptStore.TranscriptFileName), "{ not json");
        using var model = await Loaded();

        Assert.AreEqual(1, model.IssueCount);
        Assert.IsTrue(model.HasIssues);
        Assert.HasCount(3, model.Rows, "A broken transcript does not hide its recording");
        Assert.IsTrue(model.HasNoTranscript);
    }

    [TestMethod]
    public async Task ChangesAreAnnouncedToBindings()
    {
        CopyMacLibrary(_root.Path);
        using var model = await Loaded();
        var changed = new List<string?>();
        ((INotifyPropertyChanged)model).PropertyChanged += (_, args) => changed.Add(args.PropertyName);

        model.Selected = model.Rows.Single(row => row.Id == Id(3));

        CollectionAssert.IsSubsetOf(
            new[] { nameof(LibraryViewModel.Selected), nameof(LibraryViewModel.SelectedTitle), nameof(LibraryViewModel.HasTranscript), nameof(LibraryViewModel.HasNoTranscript) },
            changed);
    }
}
