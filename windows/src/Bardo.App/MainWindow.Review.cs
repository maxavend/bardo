using System.Runtime.InteropServices;
using Bardo.Capture;
using Bardo.Library;
using Bardo.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;
using Windows.Graphics.Imaging;

namespace Bardo.App;

/// <summary>
/// The design review: with <c>--design-review &lt;folder&gt;</c>, Bardo opens a made-up
/// Library, walks through its main states and saves a picture of its own window for each,
/// then quits. CI runs it so the interface can be seen without a Windows PC. Nothing is
/// recorded and no real Library is touched.
/// </summary>
public sealed partial class MainWindow
{
    internal static string? DesignReviewFolder(IReadOnlyList<string> arguments)
    {
        var index = arguments.ToList().IndexOf("--design-review");
        return index >= 0 && index + 1 < arguments.Count ? arguments[index + 1] : null;
    }

    internal static async Task<WindowEnvironment> DesignReviewEnvironmentAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), $"BardoDesignReview-{Guid.NewGuid()}");
        var library = Path.Combine(root, "Library");
        await DemoLibrary.SeedAsync(library, DateTimeOffset.Now);
        var preferences = new PreferencesStore(root);
        preferences.Update(current => current with { LocalName = "Maxi" });
        return new WindowEnvironment(library, preferences, Path.Combine(root, "Models"), _ => new DemoCaptureService());
    }

    internal async Task RunDesignReviewAsync(string folder)
    {
        Directory.CreateDirectory(folder);
        var root = (FrameworkElement)Content;
        AppWindow.Move(new PointInt32(0, 0));
        await Settle();
        // Logical 1280 x 800, as large as the screen's scale makes it in pixels.
        var scale = root.XamlRoot?.RasterizationScale ?? 1;
        AppWindow.Resize(new SizeInt32((int)(1280 * scale), (int)(800 * scale)));
        await LoadAsync();
        await Settle();
        await File.WriteAllTextAsync(Path.Combine(folder, "display.txt"),
            $"Scale {scale:0.##}, window {AppWindow.Size.Width}x{AppWindow.Size.Height}");

        foreach (var theme in new[] { ElementTheme.Dark, ElementTheme.Light })
        {
            root.RequestedTheme = theme;
            var suffix = theme == ElementTheme.Dark ? "oscuro" : "claro";

            // First launch: choosing, then downloading.
            Onboarding.Preview(OnboardingState.Choosing);
            await Capture(folder, $"00-bienvenida-{suffix}");
            Onboarding.Preview(OnboardingState.Downloading, 0.42);
            await Capture(folder, $"00-bienvenida-descargando-{suffix}");
            Onboarding.Close();

            // A conversation with two participants, part played.
            ViewModel.Select(ViewModel.Rows[0].Id);
            ParticipantsExpander.IsExpanded = true;
            await WaitFor(() => Playback.IsAvailable && Playback.Duration > 1);
            await Settle();
            Playback.Seek(Playback.Duration * 0.42);
            await Capture(folder, $"01-conversacion-{suffix}");

            // A call transcribed per track: you and the others.
            ViewModel.Select(ViewModel.Rows.First(row => row.Recording.Sources.Contains(Bardo.Domain.AudioSource.SystemAudio)).Id);
            await WaitFor(() => Playback.IsAvailable && Playback.Duration > 1);
            Playback.Seek(Playback.Duration * 0.7);
            await Capture(folder, $"02-llamada-{suffix}");

            // Not transcribed yet.
            ViewModel.Select(ViewModel.Rows.First(row => row.Title == "Idea para el onboarding").Id);
            await Capture(folder, $"03-sin-transcripcion-{suffix}");

            // The live recorder in a meeting, twelve seconds in, with marks.
            Recorder.Start(CaptureMode.Meeting, null);
            var session = ((DemoCaptureService)_captures).Session!;
            for (var tick = 0; tick < RecorderViewModel.LiveBars; tick++)
            {
                session.Elapsed += RecorderViewModel.SecondsPerBar;
                if (tick == 70) Recorder.AddSection();
                if (tick == 160) Recorder.AddMoment();
                Recorder.Tick();
            }
            await Capture(folder, $"04-grabador-{suffix}");
            await Recorder.StopAsync(_preferences.Current.Encoding);

            // Settings.
            Navigation.SelectedItem = Navigation.SettingsItem;
            await Capture(folder, $"05-configuracion-{suffix}");
            Navigation.SelectedItem = Navigation.MenuItems.OfType<NavigationViewItem>().First();

            // A search with no results.
            ViewModel.Query = "presupuesto";
            SearchBox.Text = "presupuesto";
            await Capture(folder, $"06-sin-resultados-{suffix}");
            ViewModel.Query = "";
            SearchBox.Text = "";
        }

        // The smallest size people use, where nothing may be cut off.
        root.RequestedTheme = ElementTheme.Dark;
        AppWindow.Resize(new SizeInt32((int)(980 * scale), (int)(620 * scale)));
        ViewModel.Select(ViewModel.Rows[0].Id);
        await WaitFor(() => Playback.IsAvailable);
        await Capture(folder, "07-ventana-pequena");

        Close();
    }

    private static Task Settle() => Task.Delay(TimeSpan.FromMilliseconds(900));

    private static async Task WaitFor(Func<bool> condition)
    {
        for (var attempt = 0; attempt < 50 && !condition(); attempt++) await Task.Delay(100);
    }

    /// <summary>Saves the window as Windows draws it, Mica and composition included.</summary>
    private async Task Capture(string folder, string name)
    {
        await Settle();
        var window = WinRT.Interop.WindowNative.GetWindowHandle(this);
        GetWindowRect(window, out var rect);
        var width = rect.Right - rect.Left;
        var height = rect.Bottom - rect.Top;
        var screen = GetDC(IntPtr.Zero);
        var memory = CreateCompatibleDC(screen);
        var bitmap = CreateCompatibleBitmap(screen, width, height);
        var previous = SelectObject(memory, bitmap);
        try
        {
            PrintWindow(window, memory, RenderFullContent);
            var info = new BitmapInfoHeader
            {
                Size = (uint)Marshal.SizeOf<BitmapInfoHeader>(),
                Width = width,
                Height = -height,
                Planes = 1,
                BitCount = 32,
            };
            var pixels = new byte[width * height * 4];
            SelectObject(memory, previous);
            GetDIBits(memory, bitmap, 0, (uint)height, pixels, ref info, 0);

            await using var file = File.Create(Path.Combine(folder, $"{name}.png"));
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, file.AsRandomAccessStream());
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)width, (uint)height, 96, 96, pixels);
            await encoder.FlushAsync();
        }
        finally
        {
            DeleteObject(bitmap);
            DeleteDC(memory);
            ReleaseDC(IntPtr.Zero, screen);
        }
    }

    private const uint RenderFullContent = 2;

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfoHeader
    {
        public uint Size;
        public int Width;
        public int Height;
        public ushort Planes;
        public ushort BitCount;
        public uint Compression;
        public uint SizeImage;
        public int XPelsPerMeter;
        public int YPelsPerMeter;
        public uint ClrUsed;
        public uint ClrImportant;
    }

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr window, out Rect rect);

    [DllImport("user32.dll")]
    private static extern bool PrintWindow(IntPtr window, IntPtr deviceContext, uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr window, IntPtr deviceContext);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr deviceContext);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleBitmap(IntPtr deviceContext, int width, int height);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr deviceContext, IntPtr gdiObject);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr gdiObject);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(IntPtr deviceContext);

    [DllImport("gdi32.dll")]
    private static extern int GetDIBits(IntPtr deviceContext, IntPtr bitmap, uint start, uint lines, byte[] bits, ref BitmapInfoHeader info, uint usage);
}
