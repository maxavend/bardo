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
        var preferences = new PreferencesStore(root);
        // The portfolio's made-up week, as the macOS captures show it; the short demo otherwise.
        var script = Path.Combine(AppContext.BaseDirectory, "Assets", "portfolio-conversations.json");
        if (File.Exists(script))
        {
            var conversations = DemoLibrary.FromScript(await File.ReadAllTextAsync(script), DateTimeOffset.Now);
            var seeded = await DemoLibrary.SeedAsync(library, conversations);
            preferences.Update(current => DemoLibrary.Favorites(conversations, seeded).Aggregate(current, (prefs, id) => prefs.TogglingFavorite(id)));
        }
        else
        {
            await DemoLibrary.SeedAsync(library, DateTimeOffset.Now);
        }
        return new WindowEnvironment(library, preferences, Path.Combine(root, "Models"), _ => new DemoCaptureService());
    }

    internal async Task RunDesignReviewAsync(string folder)
    {
        Directory.CreateDirectory(folder);
        var root = (FrameworkElement)Content;
        AppWindow.Move(new PointInt32(0, 0));
        await Settle();
        // Logical 1260 x 700, as large as the screen's scale makes it in pixels: on the
        // CI machine, 1920 x 1080 at 150 %, about 1890 x 1050.
        var scale = root.XamlRoot?.RasterizationScale ?? 1;
        AppWindow.Resize(new SizeInt32((int)(1260 * scale), (int)(700 * scale)));
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

            // From here on, as a set-up app: models installed, nothing left to download. The
            // notice is closed once the Library has shown, which first opens it.
            await Settle();
            SetupBar.IsOpen = false;
            ViewModel.Transcriber ??= new ReviewEngine();
            ViewModel.SpeakerIdentifier ??= new ReviewEngine();

            // A conversation with several participants, part played.
            ViewModel.Select(Row(row => row.Recording.Notes.Sections.Count > 0).Id);
            ParticipantsExpander.IsExpanded = true;
            await WaitFor(() => Playback.IsAvailable && Playback.Duration > 1);
            await Settle();
            Playback.Seek(Playback.Duration * 0.42);
            await Capture(folder, $"01-conversacion-{suffix}");

            // Listening to some participants only, chosen in the player.
            ViewModel.SetListened(ViewModel.Speakers[^1].Id, false);
            OnChooseListened(ListenButton, new RoutedEventArgs());
            await Capture(folder, $"09-escuchar-a-{suffix}");
            foreach (var popup in Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(Content.XamlRoot)) popup.IsOpen = false;
            ViewModel.ListenToEveryone();

            // A waveform still being read: placeholder bars until it is ready.
            PlaybackWaveform.ShowLoading();
            await Capture(folder, $"10-onda-cargando-{suffix}");
            ShowSpeakers();

            // The same conversation to read: its sections and moment among the turns.
            ParticipantsExpander.IsExpanded = false;
            await Settle();
            var transcriptTop = TranscriptBlocks.TransformToVisual((UIElement)DetailScroll.Content).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
            DetailScroll.ChangeView(null, Math.Max(0, transcriptTop - 8), null, disableAnimation: true);
            await Capture(folder, $"08-lectura-{suffix}");
            DetailScroll.ChangeView(null, 0, null, disableAnimation: true);
            ParticipantsExpander.IsExpanded = true;

            // A call transcribed per track: you and the others.
            ViewModel.Select(Row(row => row.Recording.Sources.Count == 2 && row.Recording.ProcessingState == Bardo.Domain.ProcessingState.Completed && row.Recording.Notes.IsEmpty).Id);
            await WaitFor(() => Playback.IsAvailable && Playback.Duration > 1);
            Playback.Seek(Playback.Duration * 0.7);
            await Capture(folder, $"02-llamada-{suffix}");

            // Not transcribed yet.
            ViewModel.Select(Row(row => row.Recording.ProcessingState == Bardo.Domain.ProcessingState.Pending).Id);
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
            ViewModel.Query = "Antártica";
            SearchBox.Text = "Antártica";
            await Capture(folder, $"06-sin-resultados-{suffix}");
            ViewModel.Query = "";
            SearchBox.Text = "";
        }

        // The smallest size people use, where nothing may be cut off.
        root.RequestedTheme = ElementTheme.Dark;
        AppWindow.Resize(new SizeInt32((int)(980 * scale), (int)(620 * scale)));
        ViewModel.Select(Row(row => row.Recording.Notes.Sections.Count > 0).Id);
        await WaitFor(() => Playback.IsAvailable);
        await Capture(folder, "07-ventana-pequena");

        Close();
    }

    /// <summary>Stands in for Whisper and sherpa-onnx, so the review shows a set-up app. It never runs.</summary>
    private sealed class ReviewEngine : ITranscriber, ISpeakerIdentifier
    {
        public Task<Bardo.Domain.Transcript> TranscribeAsync(Bardo.Domain.Recording recording, IProgress<WorkProgress> progress, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("The design review does not transcribe.");

        public Task<Bardo.Domain.Transcript> IdentifySpeakersAsync(Bardo.Domain.Recording recording, Bardo.Domain.Transcript transcript, IProgress<WorkProgress> progress, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("The design review does not identify speakers.");
    }

    private RecordingRow Row(Func<RecordingRow, bool> matches) => ViewModel.Rows.FirstOrDefault(matches) ?? ViewModel.Rows[0];

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

            // Only what is visible: the window rectangle also holds the invisible resize border.
            var visible = rect;
            if (DwmGetWindowAttribute(window, ExtendedFrameBounds, out var frame, Marshal.SizeOf<Rect>()) == 0) visible = frame;
            var left = Math.Clamp(visible.Left - rect.Left, 0, width - 1);
            var top = Math.Clamp(visible.Top - rect.Top, 0, height - 1);
            var cropWidth = Math.Clamp(visible.Right - visible.Left, 1, width - left);
            var cropHeight = Math.Clamp(visible.Bottom - visible.Top, 1, height - top);
            var cropped = new byte[cropWidth * cropHeight * 4];
            for (var row = 0; row < cropHeight; row++)
            {
                Buffer.BlockCopy(pixels, ((top + row) * width + left) * 4, cropped, row * cropWidth * 4, cropWidth * 4);
            }

            await using var file = File.Create(Path.Combine(folder, $"{name}.png"));
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, file.AsRandomAccessStream());
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)cropWidth, (uint)cropHeight, 96, 96, cropped);
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
    private const int ExtendedFrameBounds = 9;

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect value, int size);

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
