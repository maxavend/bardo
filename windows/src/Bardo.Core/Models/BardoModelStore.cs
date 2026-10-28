namespace Bardo.Models;

public enum BardoModelStoreErrorKind
{
    InvalidPrivateRoot,
    InvalidModelRoot,
    ModelRootIsNotDirectory,
}

public sealed class BardoModelStoreException : IOException
{
    private BardoModelStoreException(BardoModelStoreErrorKind kind, string message, ManagedModel? model = null)
        : base(message)
    {
        Kind = kind;
        Model = model;
    }

    public BardoModelStoreErrorKind Kind { get; }
    public ManagedModel? Model { get; }

    internal static BardoModelStoreException InvalidPrivateRoot() =>
        new(BardoModelStoreErrorKind.InvalidPrivateRoot, "Bardo's private model root must not resolve through a symbolic link.");

    internal static BardoModelStoreException InvalidModelRoot(ManagedModel model) =>
        new(BardoModelStoreErrorKind.InvalidModelRoot, $"The managed root for {model} is outside Bardo's model root.", model);

    internal static BardoModelStoreException ModelRootIsNotDirectory(ManagedModel model) =>
        new(BardoModelStoreErrorKind.ModelRootIsNotDirectory, $"The managed root for {model} is not a directory.", model);
}

/// <summary>
/// Where Bardo keeps its downloaded models: one private folder per model under one root,
/// so removing a model can never reach anything else.
/// </summary>
public sealed class BardoModelStore
{
    private readonly string _rootPath;

    public BardoModelStore(string rootPath)
    {
        _rootPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(rootPath));
    }

    public string RootPath => _rootPath;

    /// <summary><c>%LOCALAPPDATA%\Bardo\Models</c>: per user, never roamed.</summary>
    public static string DefaultRootPath() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.Create),
        "Bardo",
        "Models");

    /// <exception cref="BardoModelStoreException">The root is reached through a link.</exception>
    public static BardoModelStore Live()
    {
        var store = new BardoModelStore(DefaultRootPath());
        store.ValidatePrivateRoot();
        return store;
    }

    public string Root(ManagedModel model) => Path.Combine(_rootPath, DirectoryName(model));

    /// <summary>Removes one model's folder and everything in it; nothing else is touched.</summary>
    /// <exception cref="BardoModelStoreException">The root or the model's folder is not Bardo's own.</exception>
    public void Reset(ManagedModel model)
    {
        ValidatePrivateRoot();
        var modelRoot = ValidatedRoot(model);
        if (File.Exists(modelRoot)) throw BardoModelStoreException.ModelRootIsNotDirectory(model);
        if (!Directory.Exists(modelRoot)) return;
        Directory.Delete(modelRoot, recursive: true);
    }

    private string ValidatedRoot(ManagedModel model)
    {
        var expectedRoot = Path.GetFullPath(Root(model));
        var parent = Path.GetDirectoryName(expectedRoot);
        if (!string.Equals(parent, _rootPath, StringComparison.Ordinal)
            || string.Equals(expectedRoot, _rootPath, StringComparison.Ordinal)
            || IsLink(expectedRoot))
        {
            throw BardoModelStoreException.InvalidModelRoot(model);
        }
        return expectedRoot;
    }

    /// <summary>
    /// Rejects a model root that is a symbolic link or a junction. A root that does not
    /// exist yet, as on a computer that has never run Bardo, is valid.
    /// </summary>
    private void ValidatePrivateRoot()
    {
        if (IsLink(_rootPath)) throw BardoModelStoreException.InvalidPrivateRoot();
    }

    private static bool IsLink(string path)
    {
        var info = new DirectoryInfo(path);
        return info.Exists && info.LinkTarget is not null;
    }

    private static string DirectoryName(ManagedModel model) => model switch
    {
        ManagedModel.WhisperTurbo => "whisper-turbo",
        ManagedModel.WhisperLarge => "whisper-large-v3",
        ManagedModel.SpeakerIdentification => "speaker-identification",
        _ => throw new ArgumentOutOfRangeException(nameof(model)),
    };
}
