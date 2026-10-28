using Bardo.Persistence;
using Microsoft.VisualBasic.FileIO;

namespace Bardo.App.Services;

/// <summary>Moves Library items to the Recycle Bin, where they can be restored.</summary>
internal sealed class WindowsRecycleBin : IRecycleBin
{
    public void Recycle(string path)
    {
        if (Directory.Exists(path))
        {
            FileSystem.DeleteDirectory(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
        }
        else
        {
            FileSystem.DeleteFile(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
        }
    }
}
