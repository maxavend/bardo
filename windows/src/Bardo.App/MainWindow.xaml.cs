using System.ComponentModel;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using Bardo.App.Services;
using Bardo.Audio;
using Bardo.Capture;
using Bardo.Downloads;
using Bardo.Library;
using Bardo.Persistence;
using Bardo.Settings;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage.Pickers;

namespace Bardo.App;

[SuppressMessage("Reliability", "CA1001", Justification = "Everything disposable is released when the window closes.")]
public sealed partial class MainWindow : Window
{
    private readonly DispatcherQueueTimer _reloadTimer;
    private readonly DispatcherQueueTimer _recorderTimer;
    private readonly HttpClient _http = new();
    private readonly PreferencesStore _preferences;
    private readonly ICaptureService _captures;
    private readonly EngineHost _engines;
    private FileSystemWatcher? _watcher;
    private IReadOnlyList<CaptureManifest> _interrupted = [];
    private readonly Dictionary<Guid, float[]> _overviews = [];
    private CancellationTokenSource? _overviewLoad;

    public MainWindow() : this(WindowEnvironment.Live())
    {
    }

    internal MainWindow(WindowEnvironment environment)
    {
        _preferences = environment.Preferences;
        ViewModel = new LibraryViewModel(
            environment.LibraryPath,
            _preferences,
            new WindowsRecycleBin(),
            new MediaFoundationMetadataReader());
        var models = new ModelSetup(new ModelDownloader(environment.ModelsDirectory, _http));
        Settings = new SettingsViewModel(_preferences, models);
        Onboarding = new OnboardingViewModel(_preferences, Settings);
        _captures = environment.Captures(ViewModel.RecordingStore);
        Recorder = new RecorderViewModel(_captures);
        Playback = new PlaybackController(DispatcherQueue.GetForCurrentThread(), ViewModel.RecordingStore);
        _engines = new EngineHost(ViewModel, models, _preferences);

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

        _recorderTimer = DispatcherQueue.CreateTimer();
        _recorderTimer.Interval = TimeSpan.FromMilliseconds(50);
        _recorderTimer.Tick += (_, _) => Recorder.Tick();

        ViewModel.PropertyChanged += OnViewModelChanged;
        Playback.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(PlaybackController.Position) or nameof(PlaybackController.Duration))
            {
                PlaybackWaveform.Progress = Playback.Position / Math.Max(0.01, Playback.Duration);
            }
        };
        Recorder.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(RecorderViewModel.Live)) LiveWaveform.ShowLive(Recorder.Live);
        };
        PlaybackWaveform.SeekRequested += (_, fraction) => Playback.Seek(fraction * Playback.Duration);
        PlaybackWaveform.StepRequested += (_, seconds) => Playback.SkipBy(seconds);
        Settings.ModelsChanged += (_, _) => _engines.Refresh();
        Closed += OnClosed;

        _engines.Refresh();
        CheckSortMenu();
        _ = LoadAsync();
        ShowInterruptedCaptures();
    }

    public LibraryViewModel ViewModel { get; }

    public SettingsViewModel Settings { get; }

    public OnboardingViewModel Onboarding { get; }

    public RecorderViewModel Recorder { get; }

    public PlaybackController Playback { get; }

    private async Task LoadAsync()
    {
        try
        {
            await ViewModel.LoadAsync();
        }
        catch (RecordingStoreException error)
        {
            ViewModel.ShowNotice(error.Message, isError: true);
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
            // Bardo's own jobs reload when they finish; a copy settles before it is read.
            if (ViewModel.IsWorking || Recorder.IsFinishing) return;
            _reloadTimer.Stop();
            _reloadTimer.Start();
        });

    private async void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(LibraryViewModel.Selected))
        {
            await Playback.LoadAsync(ViewModel.Selected?.Recording);
            await ShowOverviewAsync();
        }
        else if (e.PropertyName == nameof(LibraryViewModel.SelectedTranscript))
        {
            // Naming or identifying participants recolours the waveform.
            ShowSpeakers();
        }
    }

    /// <summary>The selected conversation's waveform, read once from its audio and then kept.</summary>
    private async Task ShowOverviewAsync()
    {
        _overviewLoad?.Cancel();
        if (ViewModel.Selected?.Recording is not { } recording || recording.PlaybackAudioAssets.FirstOrDefault() is not { } asset)
        {
            PlaybackWaveform.Clear();
            return;
        }
        if (!_overviews.ContainsKey(recording.Id))
        {
            PlaybackWaveform.Clear();
            using var cancellation = new CancellationTokenSource();
            _overviewLoad = cancellation;
            try
            {
                var path = await ViewModel.RecordingStore.ManagedAudioPathAsync(recording.Id, asset.Id);
                _overviews[recording.Id] = await Waveform.OverviewAsync(
                    new MediaFoundationDecoder(), path, recording.Duration ?? asset.Metadata.Duration, cancellation.Token);
            }
            catch (Exception error) when (error is OperationCanceledException or RecordingStoreException or IOException or System.Runtime.InteropServices.COMException)
            {
                return;
            }
            finally
            {
                if (_overviewLoad == cancellation) _overviewLoad = null;
            }
            if (ViewModel.Selected?.Id != recording.Id) return;
        }
        ShowSpeakers();
    }

    private void ShowSpeakers()
    {
        if (ViewModel.Selected?.Recording is not { } recording || !_overviews.TryGetValue(recording.Id, out var levels)) return;
        var duration = recording.Duration ?? Playback.Duration;
        PlaybackWaveform.ShowOverview(levels, Waveform.Speakers(ViewModel.SelectedTranscript, duration, levels.Length));
        PlaybackWaveform.Progress = Playback.Position / Math.Max(0.01, Playback.Duration);
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _overviewLoad?.Cancel();
        _watcher?.Dispose();
        _recorderTimer.Stop();
        _engines.Dispose();
        Playback.Dispose();
        Settings.Dispose();
        ViewModel.Dispose();
        _http.Dispose();
    }

    // Navigation and search

    private void OnSectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var showsSettings = args.IsSettingsSelected;
        LibraryContent.Visibility = showsSettings ? Visibility.Collapsed : Visibility.Visible;
        // Library notices, such as "open Settings", have no place in Settings itself.
        LibraryNotices.Visibility = showsSettings ? Visibility.Collapsed : Visibility.Visible;
        SettingsContent.Visibility = showsSettings ? Visibility.Visible : Visibility.Collapsed;
        if (args.SelectedItem is NavigationViewItem { Tag: string tag } && Enum.TryParse<LibrarySection>(tag, out var section))
        {
            ViewModel.Section = section;
        }
    }

    private void OnOpenSettings(object sender, RoutedEventArgs e) => Navigation.SelectedItem = Navigation.SettingsItem;

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

    private void OnSort(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string tag } && Enum.TryParse<LibrarySort>(tag, out var sort)) ViewModel.Sort = sort;
        CheckSortMenu();
    }

    private void CheckSortMenu()
    {
        foreach (var item in SortMenu.Items.OfType<RadioMenuFlyoutItem>())
        {
            item.IsChecked = (string)item.Tag == ViewModel.Sort.ToString();
        }
    }

    private void OnNoticeClosed(InfoBar sender, object args) => ViewModel.DismissNotice();

    private void OnOpenLibraryFolder(object sender, RoutedEventArgs e) => OpenInExplorer(ViewModel.LibraryPath);

    private void OnShowInFolder(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Selected is { } row) OpenInExplorer(ViewModel.RecordingStore.RecordingDirectoryPath(row.Id));
    }

    private static void OpenInExplorer(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
    }

    // Recording

    private void OnRecord(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string tag } || !Enum.TryParse<CaptureMode>(tag, out var mode)) return;
        try
        {
            Recorder.Start(mode, _preferences.Current.MicrophoneDeviceId);
            _recorderTimer.Start();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            ViewModel.ShowNotice(Localized.Format("RecordingFailed", error.Message), isError: true);
        }
    }

    private void OnTogglePauseRecording(object sender, RoutedEventArgs e) => Recorder.TogglePause();

    private void OnToggleMute(object sender, RoutedEventArgs e) => Recorder.IsMicrophoneMuted = !Recorder.IsMicrophoneMuted;

    private void OnAddMoment(object sender, RoutedEventArgs e) => Recorder.AddMoment();

    private void OnAddSection(object sender, RoutedEventArgs e) => Recorder.AddSection();

    private async void OnStopRecording(object sender, RoutedEventArgs e)
    {
        try
        {
            var recording = await Recorder.StopAsync(_preferences.Current.Encoding);
            _recorderTimer.Stop();
            await LoadAsync();
            if (recording is null) return;
            ViewModel.Select(recording.Id);
            if (ViewModel.CanTranscribeSelected) await ViewModel.TranscribeAsync(recording.Id);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or RecordingStoreException or System.Runtime.InteropServices.COMException)
        {
            _recorderTimer.Stop();
            ViewModel.ShowNotice(Localized.Format("RecordingFailed", error.Message), isError: true);
            ShowInterruptedCaptures();
        }
    }

    private void ShowInterruptedCaptures()
    {
        _interrupted = _captures.Interrupted();
        RecoveryBar.Message = Localized.Format("RecoveryMessage", _interrupted.Count);
        RecoveryBar.IsOpen = _interrupted.Count > 0 && !Recorder.IsRecording;
    }

    private async void OnRecoverCaptures(object sender, RoutedEventArgs e)
    {
        RecoveryBar.IsOpen = false;
        foreach (var manifest in _interrupted)
        {
            try
            {
                await _captures.PublishAsync(manifest, _preferences.Current.Encoding, CancellationToken.None);
            }
            catch (Exception error) when (error is IOException or InvalidDataException or RecordingStoreException or System.Runtime.InteropServices.COMException)
            {
                ViewModel.ShowNotice(Localized.Format("RecordingFailed", error.Message), isError: true);
            }
        }
        await LoadAsync();
        ShowInterruptedCaptures();
    }

    // Importing

    private async void OnImport(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.MusicLibrary };
        foreach (var extension in AudioImporter.SupportedFileExtensions) picker.FileTypeFilter.Add($".{extension}");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var files = await picker.PickMultipleFilesAsync();
        if (files is null || files.Count == 0) return;
        await ViewModel.ImportAsync([.. files.Select(file => file.Path)]);
        if (ViewModel.Selected is { } row && ViewModel.CanTranscribeSelected) await ViewModel.TranscribeAsync(row.Id);
    }

    // The selected conversation

    private async void OnTranscribe(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Selected is { } row) await ViewModel.TranscribeAsync(row.Id);
    }

    private async void OnIdentifySpeakers(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Selected is { } row) await ViewModel.IdentifySpeakersAsync(row.Id);
    }

    private void OnCancelWork(object sender, RoutedEventArgs e) => ViewModel.CancelWork();

    private void OnCopyTranscript(object sender, RoutedEventArgs e)
    {
        if (ViewModel.SelectedTranscriptText() is not { } text) return;
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    private void OnToggleFavorite(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Selected is { } row) ViewModel.ToggleFavorite(row.Id);
    }

    private async void OnRename(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Selected is not { } row) return;
        if (await AskForText(Localized.Get("RenameDialogTitle"), row.Title) is { } title)
        {
            await ViewModel.RenameAsync(row.Id, title);
        }
    }

    private async void OnRecycle(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Selected is not { } row) return;
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = Localized.Format("RecycleDialogTitle", row.Title),
            Content = Localized.Get("RecycleDialogBody"),
            PrimaryButtonText = Localized.Get("RecycleDialogConfirm"),
            CloseButtonText = Localized.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await ViewModel.MoveToRecycleBinAsync(row.Id);
    }

    /// <summary>A participant's actions in one menu, so their name keeps the row's width.</summary>
    private void OnSpeakerActions(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: Guid id } button) return;
        var menu = new MenuFlyout();
        var rename = new MenuFlyoutItem { Text = Localized.Get("RenameSpeakerMenu"), Icon = new FontIcon { Glyph = "\uE8AC" } };
        rename.Click += async (_, _) => await RenameSpeakerAsync(id);
        menu.Items.Add(rename);
        var merge = new MenuFlyoutSubItem { Text = Localized.Get("MergeSpeakerMenu") };
        foreach (var other in ViewModel.Speakers.Where(speaker => speaker.Id != id))
        {
            var item = new MenuFlyoutItem { Text = other.DisplayName };
            item.Click += async (_, _) => await ViewModel.MergeSpeakersAsync(id, other.Id);
            merge.Items.Add(item);
        }
        merge.IsEnabled = merge.Items.Count > 0;
        menu.Items.Add(merge);
        menu.ShowAt(button, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight });
    }

    private async Task RenameSpeakerAsync(Guid id)
    {
        if (ViewModel.Speakers.FirstOrDefault(speaker => speaker.Id == id) is not { } speaker) return;
        if (await AskForText(Localized.Get("RenameSpeakerTitle"), speaker.IsNamed ? speaker.DisplayName : "") is { } name)
        {
            await ViewModel.RenameSpeakerAsync(id, name);
        }
    }

    /// <summary>A small dialog with one text box; null when cancelled.</summary>
    private async Task<string?> AskForText(string title, string text)
    {
        var box = new TextBox { Text = text, SelectionStart = 0, SelectionLength = text.Length };
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = title,
            Content = box,
            PrimaryButtonText = Localized.Get("Save"),
            CloseButtonText = Localized.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary ? box.Text : null;
    }

    // Playback

    private void OnTogglePlay(object sender, RoutedEventArgs e) => Playback.TogglePlay();

    private void OnSkipBack(object sender, RoutedEventArgs e) => Playback.SkipBy(-10);

    private void OnPlayFromBlock(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: double start }) Playback.Seek(start, play: true);
    }
}

/// <summary>Where the window keeps its Library and Settings, and how it records.</summary>
internal sealed record WindowEnvironment(
    string LibraryPath,
    PreferencesStore Preferences,
    string ModelsDirectory,
    Func<RecordingStore, ICaptureService> Captures)
{
    public static WindowEnvironment Live() => new(
        RecordingStore.DefaultLibraryPath(),
        PreferencesStore.Live(),
        ModelCatalog.DefaultDirectory(),
        store => new WasapiCaptureService(store, CaptureStaging.Live()));
}
