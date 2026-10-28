using Bardo.Resources;
using Bardo.Serialization;

namespace Bardo.Persistence;

public enum DurableFileFailure
{
    Write,
    Rename,
}

public sealed class DurableFileException(DurableFileFailure failure, string path, string description)
    : IOException(failure == DurableFileFailure.Write
        ? Strings.CouldNotWrite(path, description)
        : Strings.CouldNotPublish(path, description))
{
    public DurableFileFailure Failure { get; } = failure;
    public string Path { get; } = path;
}

/// <summary>
/// Crash-safe, owner-only file publication shared by Bardo's stores.
/// </summary>
/// <remarks>
/// Data is written to a same-directory temporary file, flushed to stable storage and
/// then moved over the destination, so readers only ever see the previous or the
/// complete new contents. Recordings and transcripts are private: on Windows they live
/// in the user's own <c>%LOCALAPPDATA%</c>; elsewhere directories are created as 0700
/// and files as 0600.
/// </remarks>
public static class DurableFile
{
    public const UnixFileMode PrivateDirectoryPermissions = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute;
    public const UnixFileMode PrivateFilePermissions = UnixFileMode.UserRead | UnixFileMode.UserWrite;

    public static void Write(ReadOnlySpan<byte> data, string destinationPath, string temporaryPrefix)
    {
        var directory = System.IO.Path.GetDirectoryName(destinationPath)!;
        var temporaryPath = System.IO.Path.Combine(directory, $"{temporaryPrefix}-{Guid.NewGuid().ToUuidString()}.tmp");

        try
        {
            WriteSynchronously(data, temporaryPath);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            TryDelete(temporaryPath);
            throw new DurableFileException(DurableFileFailure.Write, System.IO.Path.GetFileName(destinationPath), error.Message);
        }

        try
        {
            Rename(temporaryPath, destinationPath);
        }
        catch
        {
            TryDelete(temporaryPath);
            throw;
        }
    }

    /// <summary>Atomically replaces <paramref name="destinationPath"/> with <paramref name="sourcePath"/> on the same volume.</summary>
    public static void Rename(string sourcePath, string destinationPath)
    {
        try
        {
            File.Move(sourcePath, destinationPath, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new DurableFileException(DurableFileFailure.Rename, System.IO.Path.GetFileName(destinationPath), error.Message);
        }
    }

    public static void CreatePrivateDirectory(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            Directory.CreateDirectory(path);
            return;
        }
        Directory.CreateDirectory(path, PrivateDirectoryPermissions);
        RestrictToOwner(path, PrivateDirectoryPermissions);
    }

    /// <summary>Best effort: tightens permissions of files Bardo did not create itself.</summary>
    public static void RestrictToOwner(string path, UnixFileMode permissions = PrivateFilePermissions)
    {
        if (OperatingSystem.IsWindows()) return;
        try
        {
            File.SetUnixFileMode(path, permissions);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Best effort, like the macOS app.
        }
    }

    private static void WriteSynchronously(ReadOnlySpan<byte> data, string path)
    {
        var options = new FileStreamOptions
        {
            Mode = FileMode.CreateNew,
            Access = FileAccess.Write,
            Share = FileShare.None,
            Options = FileOptions.WriteThrough,
        };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = PrivateFilePermissions;

        using var stream = new FileStream(path, options);
        stream.Write(data);
        // Pushes the bytes to the drive before the file can replace the previous one.
        stream.Flush(flushToDisk: true);
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Leftovers are reported as temporary artifacts by the Library.
        }
    }
}
