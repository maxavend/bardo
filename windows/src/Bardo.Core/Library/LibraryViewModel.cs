using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Serialization;

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
public sealed class RecordingRow(Recording recording, DateTimeOffset now)
{
    public Recording Recording { get; } = recording;
    public Guid Id => Recording.Id;
    public string Title { get; } = LibraryFormatting.RecordingTitle(recording);
    public string Details { get; } =
        $"{LibraryFormatting.ListDate(recording.CreatedAt, now)} · {DurationFormatting.Duration(recording.Duration)}";
}

/// <summary>One stretch of speech: who spoke, when, and what they said.</summary>
public sealed class TranscriptBlockRow(TranscriptTextFormatter.Block block)
{
    public string Heading { get; } = block.Speaker ?? Range(block);
    public string Time { get; } = block.Speaker is null ? "" : Range(block);
    public string Text { get; } = block.Text;

    private static string Range(TranscriptTextFormatter.Block block) =>
        $"{DurationFormatting.Duration(block.Start)}–{DurationFormatting.Duration(block.End)}";
}

/// <summary>The Library window's state: what is listed, what is selected, and its transcript.</summary>
public sealed class LibraryViewModel : ObservableModel, IDisposable
{
    private readonly RecordingStore _recordingStore;
    private readonly TranscriptStore _transcriptStore;
    private EquatableArray<Recording> _recordings = [];
    private Dictionary<Guid, Transcript?> _transcripts = [];
    private LibrarySection _section = LibrarySection.All;
    private string _query = "";
    private RecordingRow? _selected;
    private int _issueCount;
    private bool _isLoaded;

    public LibraryViewModel(string libraryPath)
    {
        LibraryPath = libraryPath;
        _recordingStore = new RecordingStore(libraryPath);
        _transcriptStore = new TranscriptStore(libraryPath);
    }

    public string LibraryPath { get; }

    public ObservableCollection<RecordingRow> Rows { get; } = [];

    public ObservableCollection<TranscriptBlockRow> Blocks { get; } = [];

    public LibrarySection Section
    {
        get => _section;
        set
        {
            if (SetProperty(ref _section, value)) ApplyFilter();
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

    public int IssueCount
    {
        get => _issueCount;
        private set
        {
            if (SetProperty(ref _issueCount, value)) OnPropertyChanged(nameof(HasIssues));
        }
    }

    public bool HasIssues => IssueCount > 0;

    public bool IsLibraryEmpty => _isLoaded && _recordings.Count == 0;

    public bool IsFilterEmpty => _isLoaded && _recordings.Count > 0 && Rows.Count == 0;

    public bool HasSelection => Selected is not null;

    public bool HasNoSelection => Selected is null && Rows.Count > 0;

    public bool HasTranscript => Selected is not null && Blocks.Count > 0;

    public bool HasNoTranscript => Selected is not null && Blocks.Count == 0;

    public string SelectedTitle => Selected?.Title ?? "";

    public string SelectedDetails => Selected is { Recording: var recording }
        ? string.Join(" · ",
            DateFormatting.LongDate(recording.CreatedAt),
            DurationFormatting.Duration(recording.Duration),
            LibraryFormatting.Sources(recording.Sources))
        : "";

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
        _isLoaded = true;
        IssueCount = snapshot.Issues.Count;
        ApplyFilter();
    }

    /// <summary>The selected transcript as plain text, as the macOS app copies it.</summary>
    public string? SelectedTranscriptText()
    {
        if (Selected is not { Recording: var recording } || Transcript(recording.Id) is not { } transcript) return null;
        return new TranscriptTextFormatter(
            LibraryFormatting.RecordingTitle(recording),
            recording.CreatedAt,
            recording.Duration,
            recording.Notes,
            LocalSpeakerName.Current).Text(transcript);
    }

    public void Dispose()
    {
        _recordingStore.Dispose();
        _transcriptStore.Dispose();
    }

    private Transcript? Transcript(Guid id) => _transcripts.GetValueOrDefault(id);

    private void ApplyFilter()
    {
        var selectedId = Selected?.Id;
        var now = DateTimeOffset.Now;
        Rows.Clear();
        foreach (var recording in _recordings.Where(recording =>
                     Section.Contains(recording) && LibrarySearch.Matches(recording, Transcript(recording.Id), Query)))
        {
            Rows.Add(new RecordingRow(recording, now));
        }
        Selected = Rows.FirstOrDefault(row => row.Id == selectedId) ?? Rows.FirstOrDefault();
        ShowSelection();
        OnPropertyChanged(nameof(IsLibraryEmpty));
        OnPropertyChanged(nameof(IsFilterEmpty));
        OnPropertyChanged(nameof(HasNoSelection));
    }

    private void ShowSelection()
    {
        Blocks.Clear();
        if (Selected is { Recording: var recording } && Transcript(recording.Id) is { } transcript)
        {
            var formatter = new TranscriptTextFormatter(recording.Title, localName: LocalSpeakerName.Current);
            foreach (var block in formatter.Blocks(transcript)) Blocks.Add(new TranscriptBlockRow(block));
        }
        OnPropertyChanged(nameof(HasSelection));
        OnPropertyChanged(nameof(HasNoSelection));
        OnPropertyChanged(nameof(HasTranscript));
        OnPropertyChanged(nameof(HasNoTranscript));
        OnPropertyChanged(nameof(SelectedTitle));
        OnPropertyChanged(nameof(SelectedDetails));
    }
}
