using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Resources;
using Bardo.Serialization;
using Bardo.Settings;

namespace Bardo.Library;

/// <summary>Property change notifications for view models, which any XAML binding reads.</summary>
public abstract class ObservableModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool SetProperty<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }

    protected void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>A recording as the Library list shows it.</summary>
public sealed class RecordingRow(Recording recording, DateTimeOffset now, bool isFavorite)
{
    public Recording Recording { get; } = recording;
    public Guid Id => Recording.Id;
    public string Title { get; } = LibraryFormatting.RecordingTitle(recording);
    public bool IsFavorite { get; } = isFavorite;
    public string Details { get; } =
        $"{LibraryFormatting.ListDate(recording.CreatedAt, now)} · {DurationFormatting.Duration(recording.Duration)}";
}

/// <summary>One stretch of speech: who spoke, when, and what they said.</summary>
public sealed class TranscriptBlockRow(TranscriptTextFormatter.Block block, int speakerIndex = -1)
{
    /// <summary>The speaker's place in the transcript, which picks their colour; -1 for no one.</summary>
    public int SpeakerIndex { get; } = speakerIndex;
    public bool HasSpeaker => SpeakerIndex >= 0;

    public string Heading { get; } = block.Speaker ?? Range(block);
    public string Time { get; } = block.Speaker is null ? "" : Range(block);
    public string Text { get; } = block.Text;
    public double Start { get; } = block.Start;
    public double End { get; } = block.End;

    private static string Range(TranscriptTextFormatter.Block block) =>
        $"{DurationFormatting.Duration(block.Start)}–{DurationFormatting.Duration(block.End)}";
}

/// <summary>A participant of the selected conversation, as the naming list shows them.</summary>
public sealed class SpeakerRow(Speaker speaker, string displayName, bool isNamed, int index = 0)
{
    /// <summary>The participant's place in the transcript, which picks their colour.</summary>
    public int Index { get; } = index;

    public Guid Id => Speaker.Id;
    public Speaker Speaker { get; } = speaker;
    public string DisplayName { get; } = displayName;
    public bool IsNamed { get; } = isNamed;
}

/// <summary>A short message after an action, and whether it reports a failure.</summary>
public sealed record LibraryNotice(string Message, bool IsError);

/// <summary>The Library window's state: what is listed, what is selected, and what is running.</summary>
public sealed class LibraryViewModel : ObservableModel, IDisposable
{
    private readonly RecordingStore _recordingStore;
    private readonly TranscriptStore _transcriptStore;
    private readonly PreferencesStore _preferences;
    private readonly IAudioMetadataReader? _metadataReader;
    private ITranscriber? _transcriber;
    private ISpeakerIdentifier? _speakerIdentifier;
    private EquatableArray<Recording> _recordings = [];
    private Dictionary<Guid, Transcript?> _transcripts = [];
    private LibrarySection _section = LibrarySection.All;
    private string _query = "";
    private RecordingRow? _selected;
    private EquatableArray<RecordingStoreIssue> _issues = [];
    private bool _isLoaded;
    private Guid? _workingRecordingId;
    private string _workDescription = "";
    private double _workProgress;
    private CancellationTokenSource? _work;
    private LibraryNotice? _notice;

    public LibraryViewModel(
        string libraryPath,
        PreferencesStore? preferences = null,
        IRecycleBin? recycleBin = null,
        IAudioMetadataReader? metadataReader = null)
    {
        LibraryPath = libraryPath;
        _recordingStore = new RecordingStore(libraryPath, recycleBin);
        _transcriptStore = new TranscriptStore(libraryPath);
        _preferences = preferences ?? new PreferencesStore(Path.GetDirectoryName(Path.GetFullPath(libraryPath))!);
        _metadataReader = metadataReader;
        LocalSpeakerName.Provider = () => _preferences.Current.LocalName;
    }

    public string LibraryPath { get; }

    public PreferencesStore Preferences => _preferences;

    public RecordingStore RecordingStore => _recordingStore;

    public ObservableCollection<RecordingRow> Rows { get; } = [];

    public ObservableCollection<TranscriptBlockRow> Blocks { get; } = [];

    public ObservableCollection<SpeakerRow> Speakers { get; } = [];

    /// <summary>The engines are set once their models are ready; until then, nothing offers to run them.</summary>
    public ITranscriber? Transcriber
    {
        get => _transcriber;
        set
        {
            _transcriber = value;
            NotifySelectionActions();
        }
    }

    public ISpeakerIdentifier? SpeakerIdentifier
    {
        get => _speakerIdentifier;
        set
        {
            _speakerIdentifier = value;
            NotifySelectionActions();
        }
    }

    public LibrarySection Section
    {
        get => _section;
        set
        {
            if (SetProperty(ref _section, value)) ApplyFilter();
        }
    }

    public LibrarySort Sort
    {
        get => _preferences.Current.Sort;
        set
        {
            if (value == Sort) return;
            _preferences.Update(current => current with { Sort = value });
            OnPropertyChanged();
            ApplyFilter();
        }
    }

    public string Query
    {
        get => _query;
        set
        {
            if (SetProperty(ref _query, value)) ApplyFilter();
        }
    }

    public RecordingRow? Selected
    {
        get => _selected;
        set
        {
            if (SetProperty(ref _selected, value)) ShowSelection();
        }
    }

    public IReadOnlyList<RecordingStoreIssue> Issues => _issues;

    public bool HasIssues => _issues.Count > 0;

    public int IssueCount => _issues.Count;

    public LibraryNotice? Notice
    {
        get => _notice;
        private set
        {
            if (SetProperty(ref _notice, value)) OnPropertyChanged(nameof(HasNotice));
        }
    }

    public bool HasNotice => Notice is not null;

    public bool IsLibraryEmpty => _isLoaded && _recordings.Count == 0;

    public bool IsFilterEmpty => _isLoaded && _recordings.Count > 0 && Rows.Count == 0;

    public bool HasSelection => Selected is not null;

    public bool HasNoSelection => Selected is null && Rows.Count > 0;

    /// <summary>Nothing listed, so nothing to show beside the list either.</summary>
    public bool ShowsEmptyDetail => IsFilterEmpty || IsLibraryEmpty;

    public bool HasTranscript => Selected is not null && Blocks.Count > 0;

    public bool HasNoTranscript => Selected is not null && Blocks.Count == 0 && !IsSelectedWorking;

    public string SelectedTitle => Selected?.Title ?? "";

    public Transcript? SelectedTranscript => Selected is { } row ? FindTranscript(row.Id) : null;

    public bool IsSelectedFavorite => Selected is { } row && _preferences.Current.IsFavorite(row.Id);

    public string SelectedDetails => Selected is { Recording: var recording }
        ? string.Join(" · ",
            DateFormatting.LongDate(recording.CreatedAt),
            DurationFormatting.Duration(recording.Duration),
            LibraryFormatting.Sources(recording.Sources))
        : "";

    public bool IsWorking => _workingRecordingId is not null;

    public bool IsSelectedWorking => _workingRecordingId is { } id && id == Selected?.Id;

    public string WorkDescription => _workDescription;

    public double WorkProgress => _workProgress;

    public bool CanTranscribeSelected => Selected is not null && Transcriber is not null && !IsWorking
        && Selected.Recording.AudioAssets.Count > 0;

    public bool CanIdentifySpeakers => Selected is { } row && SpeakerIdentifier is not null && !IsWorking
        && FindTranscript(row.Id) is { Segments.Count: > 0 };

    public bool HasSpeakers => Speakers.Count > 0;

    /// <summary>Reads the Library again, keeping the selection when it is still there.</summary>
    public async Task LoadAsync()
    {
        var snapshot = await _recordingStore.LoadLibraryAsync();
        var transcripts = new Dictionary<Guid, Transcript?>();
        foreach (var recording in snapshot.Recordings)
        {
            try
            {
                transcripts[recording.Id] = await _transcriptStore.ReadAsync(recording.Id);
            }
            catch (TranscriptStoreException)
            {
                // The recording still shows; its transcript reads as missing.
                transcripts[recording.Id] = null;
            }
        }

        _recordings = snapshot.Recordings;
        _transcripts = transcripts;
        _issues = snapshot.Issues;
        _isLoaded = true;
        OnPropertyChanged(nameof(Issues));
        OnPropertyChanged(nameof(HasIssues));
        OnPropertyChanged(nameof(IssueCount));
        ApplyFilter();
    }

    /// <summary>The selected transcript as plain text, as the macOS app copies it.</summary>
    public string? SelectedTranscriptText()
    {
        if (Selected is not { Recording: var recording } || FindTranscript(recording.Id) is not { } transcript) return null;
        return new TranscriptTextFormatter(
            LibraryFormatting.RecordingTitle(recording),
            recording.CreatedAt,
            recording.Duration,
            recording.Notes,
            LocalSpeakerName.Current).Text(transcript);
    }

    public void ToggleFavorite(Guid recordingId)
    {
        _preferences.Update(current => current.TogglingFavorite(recordingId));
        OnPropertyChanged(nameof(IsSelectedFavorite));
        ApplyFilter();
    }

    public async Task<bool> RenameAsync(Guid recordingId, string proposedTitle)
    {
        var title = proposedTitle.Trim();
        if (title.Length == 0)
        {
            Notice = new LibraryNotice(Strings.EmptyRecordingTitle, IsError: true);
            return false;
        }
        if (FindRecording(recordingId) is not { } recording) return false;
        return await Run(async () =>
        {
            await _recordingStore.UpdateAsync(recording with { Title = title });
            await LoadAsync();
            Notice = new LibraryNotice(Strings.RecordingRenamed, IsError: false);
        });
    }

    public Task<bool> MoveToRecycleBinAsync(Guid recordingId) => Run(async () =>
    {
        await _recordingStore.MoveToRecycleBinAsync(recordingId);
        if (_preferences.Current.IsFavorite(recordingId)) _preferences.Update(current => current.TogglingFavorite(recordingId));
        await LoadAsync();
        Notice = new LibraryNotice(Strings.RecordingRecycled, IsError: false);
    });

    public Task<bool> MoveIssueToRecycleBinAsync(RecordingStoreIssue issue) => Run(async () =>
    {
        await _recordingStore.MoveIssueItemToRecycleBinAsync(issue);
        await LoadAsync();
    });

    /// <summary>Copies audio files into the Library, then shows the last one imported.</summary>
    public async Task ImportAsync(IReadOnlyList<string> paths)
    {
        if (_metadataReader is null || paths.Count == 0) return;
        var importer = new AudioImporter(_recordingStore, _metadataReader);
        Recording? last = null;
        foreach (var path in paths)
        {
            try
            {
                last = await importer.ImportAsync(path);
            }
            catch (Exception error) when (error is AudioImportException or RecordingStoreException)
            {
                Notice = new LibraryNotice(error.Message, IsError: true);
            }
        }
        if (last is null) return;
        await LoadAsync();
        Select(last.Id);
        if (Notice is not { IsError: true }) Notice = new LibraryNotice(Strings.RecordingImported(LibraryFormatting.RecordingTitle(last)), IsError: false);
    }

    /// <summary>Shows a recording, clearing a section or search that would hide it.</summary>
    public void Select(Guid recordingId)
    {
        if (Rows.FirstOrDefault(row => row.Id == recordingId) is null)
        {
            _section = LibrarySection.All;
            _query = "";
            OnPropertyChanged(nameof(Section));
            OnPropertyChanged(nameof(Query));
            ApplyFilter();
        }
        Selected = Rows.FirstOrDefault(row => row.Id == recordingId) ?? Selected;
    }

    public async Task TranscribeAsync(Guid recordingId)
    {
        if (Transcriber is not { } transcriber || FindRecording(recordingId) is not { } recording || IsWorking) return;
        await RunWork(recording, Strings.Transcribing, async (progress, token) =>
        {
            await _recordingStore.UpdateAsync(recording with { ProcessingState = ProcessingState.Processing });
            try
            {
                var transcript = await transcriber.TranscribeAsync(recording, progress, token);
                await _transcriptStore.SaveAsync(transcript);
                await _recordingStore.UpdateAsync(recording with { ProcessingState = ProcessingState.Completed });
            }
            catch (OperationCanceledException)
            {
                await _recordingStore.UpdateAsync(recording with { ProcessingState = recording.ProcessingState });
                throw;
            }
            catch
            {
                await _recordingStore.UpdateAsync(recording with { ProcessingState = ProcessingState.Failed });
                throw;
            }
        }, Strings.TranscriptionFailed);
    }

    public async Task IdentifySpeakersAsync(Guid recordingId)
    {
        if (SpeakerIdentifier is not { } identifier || FindRecording(recordingId) is not { } recording
            || FindTranscript(recordingId) is not { } transcript || IsWorking)
        {
            return;
        }
        await RunWork(recording, Strings.IdentifyingSpeakers, async (progress, token) =>
        {
            var identified = await identifier.IdentifySpeakersAsync(recording, transcript, progress, token);
            await _transcriptStore.SaveAsync(identified);
        }, Strings.SpeakerIdentificationFailed);
    }

    public void CancelWork() => _work?.Cancel();

    /// <summary>Names a participant of the selected conversation; a blank name goes back to the automatic one.</summary>
    public Task<bool> RenameSpeakerAsync(Guid speakerId, string proposedName) => ChangeTranscript(transcript =>
        transcript with
        {
            Speakers = transcript.Speakers
                .Select(speaker => speaker.Id == speakerId ? speaker with { Name = proposedName.Trim().Length == 0 ? null : proposedName.Trim() } : speaker)
                .ToEquatableArray(),
        });

    /// <summary>Gives everything one participant said to another, for one person told apart as two.</summary>
    public Task<bool> MergeSpeakersAsync(Guid sourceId, Guid targetId) =>
        ChangeTranscript(transcript => transcript.MergingSpeaker(sourceId, targetId));

    public void DismissNotice() => Notice = null;

    /// <summary>Reports what happened outside the Library itself, such as a recording that could not start.</summary>
    public void ShowNotice(string message, bool isError) => Notice = new LibraryNotice(message, isError);

    public void Dispose()
    {
        _work?.Cancel();
        _work?.Dispose();
        _recordingStore.Dispose();
        _transcriptStore.Dispose();
    }

    private Recording? FindRecording(Guid id) => _recordings.FirstOrDefault(recording => recording.Id == id);

    private Transcript? FindTranscript(Guid id) => _transcripts.GetValueOrDefault(id);

    private async Task<bool> ChangeTranscript(Func<Transcript, Transcript> change)
    {
        if (Selected is not { } row || FindTranscript(row.Id) is not { } transcript) return false;
        return await Run(async () =>
        {
            var changed = change(transcript);
            if (changed == transcript) return;
            await _transcriptStore.SaveAsync(changed);
            _transcripts[row.Id] = changed;
            ShowSelection();
        });
    }

    private async Task<bool> Run(Func<Task> action)
    {
        try
        {
            await action();
            return true;
        }
        catch (Exception error) when (error is RecordingStoreException or TranscriptStoreException or IOException)
        {
            Notice = new LibraryNotice(error.Message, IsError: true);
            return false;
        }
    }

    private async Task RunWork(
        Recording recording,
        string description,
        Func<IProgress<WorkProgress>, CancellationToken, Task> work,
        Func<object?, string> failure)
    {
        using var cancellation = new CancellationTokenSource();
        _work = cancellation;
        SetWork(recording.Id, description, 0);
        // A report can arrive after the work ends; it must not bring the work back.
        var progress = new Progress<WorkProgress>(update =>
        {
            if (_work == cancellation) SetWork(recording.Id, update.Stage ?? description, Math.Clamp(update.Fraction, 0, 1));
        });
        try
        {
            await work(progress, cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            // Cancelled on purpose: nothing to report.
        }
        catch (Exception error)
        {
            Notice = new LibraryNotice(failure(error.Message), IsError: true);
        }
        finally
        {
            _work = null;
            SetWork(null, "", 0);
            await LoadAsync();
        }
    }

    private void SetWork(Guid? recordingId, string description, double progress)
    {
        _workingRecordingId = recordingId;
        _workDescription = description;
        _workProgress = progress;
        OnPropertyChanged(nameof(IsWorking));
        OnPropertyChanged(nameof(IsSelectedWorking));
        OnPropertyChanged(nameof(WorkDescription));
        OnPropertyChanged(nameof(WorkProgress));
        NotifySelectionActions();
    }

    private void ApplyFilter()
    {
        var selectedId = Selected?.Id;
        var now = DateTimeOffset.Now;
        var preferences = _preferences.Current;
        Rows.Clear();
        var visible = _recordings.Where(recording =>
            Section.Contains(recording, preferences.IsFavorite)
            && LibrarySearch.Matches(recording, FindTranscript(recording.Id), Query));
        foreach (var recording in preferences.Sort.Sorted(visible))
        {
            Rows.Add(new RecordingRow(recording, now, preferences.IsFavorite(recording.Id)));
        }
        Selected = Rows.FirstOrDefault(row => row.Id == selectedId) ?? Rows.FirstOrDefault();
        ShowSelection();
        OnPropertyChanged(nameof(IsLibraryEmpty));
        OnPropertyChanged(nameof(IsFilterEmpty));
        OnPropertyChanged(nameof(HasNoSelection));
        OnPropertyChanged(nameof(ShowsEmptyDetail));
    }

    private void ShowSelection()
    {
        Blocks.Clear();
        Speakers.Clear();
        if (Selected is { Recording: var recording } && FindTranscript(recording.Id) is { } transcript)
        {
            var localName = LocalSpeakerName.Current;
            var formatter = new TranscriptTextFormatter(recording.Title, localName: localName);
            var indices = transcript.Speakers
                .Select((speaker, index) => (Name: transcript.DisplayName(speaker, localName), index))
                .GroupBy(pair => pair.Name)
                .ToDictionary(group => group.Key, group => group.First().index);
            foreach (var block in formatter.Blocks(transcript))
            {
                Blocks.Add(new TranscriptBlockRow(block, block.Speaker is { } name && indices.TryGetValue(name, out var index) ? index : -1));
            }
            foreach (var (speaker, index) in transcript.Speakers.Select((speaker, index) => (speaker, index)))
            {
                Speakers.Add(new SpeakerRow(speaker, transcript.DisplayName(speaker, localName), speaker.Name.NonEmptyTrimmed() is not null, index));
            }
        }
        OnPropertyChanged(nameof(HasSelection));
        OnPropertyChanged(nameof(HasNoSelection));
        OnPropertyChanged(nameof(HasTranscript));
        OnPropertyChanged(nameof(SelectedTitle));
        OnPropertyChanged(nameof(SelectedTranscript));
        OnPropertyChanged(nameof(SelectedDetails));
        OnPropertyChanged(nameof(IsSelectedFavorite));
        OnPropertyChanged(nameof(HasSpeakers));
        NotifySelectionActions();
    }

    private void NotifySelectionActions()
    {
        OnPropertyChanged(nameof(HasNoTranscript));
        OnPropertyChanged(nameof(IsSelectedWorking));
        OnPropertyChanged(nameof(CanTranscribeSelected));
        OnPropertyChanged(nameof(CanIdentifySpeakers));
    }
}
