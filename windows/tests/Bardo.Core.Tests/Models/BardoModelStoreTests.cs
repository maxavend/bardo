using Bardo.Models;

namespace Bardo.Tests.Models;

[TestClass]
public sealed class BardoModelStoreTests
{
    [TestMethod]
    public void ModelRootsStayUnderInjectedRoot()
    {
        var root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        var store = new BardoModelStore(root);

        foreach (var model in Enum.GetValues<ManagedModel>())
        {
            Assert.AreEqual(Path.GetFullPath(root), Path.GetDirectoryName(store.Root(model)));
        }
    }

    /// <summary>
    /// A computer that has never run Bardo has no Bardo folder yet. The model root must
    /// still validate, or setup fails before downloading anything.
    /// </summary>
    [TestMethod]
    public void FirstLaunchAcceptsAModelRootThatDoesNotExistYet()
    {
        using var localAppData = new TemporaryDirectory("BardoFreshPC");
        var store = new BardoModelStore(Path.Combine(localAppData.Path, "Bardo", "Models") + Path.DirectorySeparatorChar);

        store.Reset(ManagedModel.WhisperTurbo);
    }

    [TestMethod]
    public void ResetRemovesOnlySelectedCurrentModel()
    {
        using var root = new TemporaryDirectory("BardoStore");
        var store = new BardoModelStore(root.Path);
        var whisper = store.Root(ManagedModel.WhisperTurbo);
        var speakers = store.Root(ManagedModel.SpeakerIdentification);
        Directory.CreateDirectory(whisper);
        Directory.CreateDirectory(speakers);
        File.WriteAllText(Path.Combine(whisper, "marker"), "whisper");
        File.WriteAllText(Path.Combine(speakers, "marker"), "speakers");

        store.Reset(ManagedModel.WhisperTurbo);

        Assert.IsFalse(Directory.Exists(whisper));
        Assert.IsTrue(Directory.Exists(speakers));
    }

    [TestMethod]
    public void ARootReachedThroughALinkIsRefused()
    {
        using var root = new TemporaryDirectory("BardoStoreLink");
        var real = Path.Combine(root.Path, "elsewhere");
        Directory.CreateDirectory(Path.Combine(real, "whisper-turbo"));
        var linked = Path.Combine(root.Path, "Models");
        try
        {
            Directory.CreateSymbolicLink(linked, real);
        }
        catch (Exception linkError) when (linkError is IOException or UnauthorizedAccessException)
        {
            Assert.Inconclusive("This account cannot create symbolic links.");
        }

        var error = Assert.ThrowsExactly<BardoModelStoreException>(() => new BardoModelStore(linked).Reset(ManagedModel.WhisperTurbo));

        Assert.AreEqual(BardoModelStoreErrorKind.InvalidPrivateRoot, error.Kind);
        Assert.IsTrue(Directory.Exists(Path.Combine(real, "whisper-turbo")));
    }

    [TestMethod]
    public void AModelRootThatIsAFileIsLeftAlone()
    {
        using var root = new TemporaryDirectory("BardoStoreFile");
        var store = new BardoModelStore(root.Path);
        File.WriteAllText(store.Root(ManagedModel.WhisperLarge), "not a folder");

        var error = Assert.ThrowsExactly<BardoModelStoreException>(() => store.Reset(ManagedModel.WhisperLarge));

        Assert.AreEqual(BardoModelStoreErrorKind.ModelRootIsNotDirectory, error.Kind);
        Assert.IsTrue(File.Exists(store.Root(ManagedModel.WhisperLarge)));
    }
}
