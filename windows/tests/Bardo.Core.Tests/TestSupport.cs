using Bardo.Domain;

namespace Bardo.Tests;

/// <summary>A folder of its own for one test, removed afterwards.</summary>
internal sealed class TemporaryDirectory : IDisposable
{
    public TemporaryDirectory(string prefix = "BardoTests")
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"{prefix}-{Guid.NewGuid()}");
        Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (IOException)
        {
            // Left in the temporary folder.
        }
    }
}

internal static class Fixtures
{
    public static Guid Id(int number) => Guid.Parse($"00000000-0000-0000-0000-{number:D12}");

    public static TranscriptMetadata Metadata(DateTimeOffset? createdAt = null) =>
        new("test", "1", "test", createdAt: createdAt);

    public static string MacLibrary => Path.Combine(AppContext.BaseDirectory, "Fixtures", "MacLibrary");

    /// <summary>A copy of the macOS Library, so a test can change it freely.</summary>
    public static void CopyMacLibrary(string destination)
    {
        foreach (var source in Directory.EnumerateFiles(MacLibrary, "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(destination, Path.GetRelativePath(MacLibrary, source));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(source, target);
        }
    }
}
