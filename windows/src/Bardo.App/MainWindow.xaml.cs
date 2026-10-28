using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using Bardo.Library;
using Bardo.Persistence;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;

namespace Bardo.App;

[SuppressMessage("Reliability", "CA1001", Justification = "The watcher is disposed when the window closes.")]
public sealed partial class MainWindow : Window
{
    private readonly DispatcherQueueTimer _reloadTimer;
    private FileSystemWatcher? _watcher;

    public MainWindow()
    {
        ViewModel = new LibraryViewModel(RecordingStore.DefaultLibraryPath());
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        AppWindow.Resize(new SizeInt32(1180, 760));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = 760;
            presenter.PreferredMinimumHeight = 480;
        }

        // Changes made outside Bardo, such as a Library copied from a Mac, show up on their own.
        _reloadTimer = DispatcherQueue.CreateTimer();
        _reloadTimer.Interval = TimeSpan.FromMilliseconds(400);
        _reloadTimer.IsRepeating = false;
        _reloadTimer.Tick += async (_, _) => await LoadAsync();

        Closed += (_, _) =>
        {
            _watcher?.Dispose();
            ViewModel.Dispose();
        };

        _ = LoadAsync();
    }

    public LibraryViewModel ViewModel { get; }

    private async Task LoadAsync()
    {
        try
        {
            await ViewModel.LoadAsync();
        }
        catch (RecordingStoreException)
        {
            // The Library folder could not be read; the empty state offers to open it.
        }
        WatchLibrary();
    }

    private void WatchLibrary()
    {
        if (_watcher is not null || !Directory.Exists(ViewModel.LibraryPath)) return;
        _watcher = new FileSystemWatcher(ViewModel.LibraryPath)
        {
            IncludeSubdirectories = true,
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite,
        };
        _watcher.Changed += OnLibraryChanged;
        _watcher.Created += OnLibraryChanged;
        _watcher.Deleted += OnLibraryChanged;
        _watcher.Renamed += OnLibraryChanged;
        _watcher.EnableRaisingEvents = true;
    }

    private void OnLibraryChanged(object sender, FileSystemEventArgs e) =>
        DispatcherQueue.TryEnqueue(() =>
        {
            // Many files change at once when a Library is copied; reload once they settle.
            _reloadTimer.Stop();
            _reloadTimer.Start();
        });

    private void OnSectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem { Tag: string tag } && Enum.TryParse<LibrarySection>(tag, out var section))
        {
            ViewModel.Section = section;
        }
    }

    private void OnSearchTextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput) ViewModel.Query = sender.Text;
    }

    private void OnFindInvoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        SearchBox.Focus(FocusState.Keyboard);
        args.Handled = true;
    }

    private void OnPaneToggleRequested(TitleBar sender, object args) => Navigation.IsPaneOpen = !Navigation.IsPaneOpen;

    private void OnRecordingSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // Clearing the list while filtering deselects nothing in the model.
        if (RecordingList.SelectedItem is RecordingRow row) ViewModel.Selected = row;
    }

    private void OnCopyTranscript(object sender, RoutedEventArgs e)
    {
        if (ViewModel.SelectedTranscriptText() is not { } text) return;
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    private void OnOpenLibraryFolder(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(ViewModel.LibraryPath);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{ViewModel.LibraryPath}\"") { UseShellExecute = true });
    }
}
