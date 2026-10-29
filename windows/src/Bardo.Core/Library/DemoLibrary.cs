using System.Buffers.Binary;
using System.Text.Json;
using Bardo.Capture;
using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Serialization;

namespace Bardo.Library;

/// <summary>How a demo conversation was captured, as the portfolio script names it.</summary>
public enum DemoKind
{
    /// <summary>A call: the microphone and the computer's audio, transcribed per track.</summary>
    Meeting,
    Microphone,
    System,
    Imported,
}

/// <summary>A moment or section marked at the start of one of a conversation's turns.</summary>
public sealed record DemoMark(int Turn, string Title, bool IsSection, string? Note = null);

/// <summary>
/// One made-up conversation: who says what, in order, and how far it got. Speakers are
/// keys such as "tu" for the person recording; <paramref name="Names"/> gives the ones
/// that were named.
/// </summary>
public sealed record DemoConversation(
    string Title,
    DateTimeOffset CreatedAt,
    DemoKind Kind,
    ProcessingState State,
    bool Diarize,
    bool Favorite,
    IReadOnlyDictionary<string, string> Names,
    IReadOnlyList<(string Speaker, string Text)> Turns,
    IReadOnlyList<DemoMark>? Marks = null,
    string? FileName = null);

/// <summary>
/// A made-up Library for design reviews, screenshots and portfolio slides: invented people
/// and conversations with speech-like audio and transcripts, so nothing private is ever
/// shown. It can follow the portfolio script the macOS captures use
/// (<c>tools/portfolio/conversations.json</c>), so both platforms tell the same story.
/// </summary>
public static class DemoLibrary
{
    public const int SampleRate = 16_000;

    /// <summary>The person recording, in the script's turns.</summary>
    public const string LocalSpeaker = "tu";

    private sealed record Turn(string Speaker, double Start, double End, string Text);

    /// <summary>Four short conversations, enough to show every state of the window.</summary>
    public static Task<IReadOnlyList<Recording>> SeedAsync(string libraryPath, DateTimeOffset now) =>
        SeedAsync(libraryPath, BuiltIn(now));

    /// <summary>
    /// The portfolio script. With <paramref name="today"/>, its week moves so the script's
    /// own "today" falls on that day and list dates read the same as in its captures.
    /// </summary>
    public static IReadOnlyList<DemoConversation> FromScript(string json, DateTimeOffset? today = null)
    {
        using var document = JsonDocument.Parse(json);
        var shift = today is { } day && document.RootElement.TryGetProperty("today", out var scripted)
            ? day.Date - DateTime.Parse(scripted.GetString()!, System.Globalization.CultureInfo.InvariantCulture).Date
            : TimeSpan.Zero;
        var conversations = new List<DemoConversation>();
        foreach (var item in document.RootElement.GetProperty("conversations").EnumerateArray())
        {
            var names = item.TryGetProperty("names", out var named) && named.ValueKind == JsonValueKind.Object
                ? named.EnumerateObject().ToDictionary(property => property.Name, property => property.Value.GetString() ?? "")
                : [];
            var turns = item.GetProperty("turns").EnumerateArray()
                .Select(turn => (turn[0].GetString() ?? "", turn[1].GetString() ?? ""))
                .ToList();
            var id = item.GetProperty("id").GetString();
            conversations.Add(new DemoConversation(
                item.GetProperty("title").GetString() ?? "",
                DateTimeOffset.Parse(item.GetProperty("createdAt").GetString()!, System.Globalization.CultureInfo.InvariantCulture) + shift,
                item.GetProperty("kind").GetString() switch
                {
                    "meeting" => DemoKind.Meeting,
                    "microphone" => DemoKind.Microphone,
                    "system" => DemoKind.System,
                    _ => DemoKind.Imported,
                },
                item.GetProperty("state").GetString() switch
                {
                    "pending" => ProcessingState.Pending,
                    "failed" => ProcessingState.Failed,
                    _ => ProcessingState.Completed,
                },
                item.TryGetProperty("diarize", out var diarize) && diarize.GetBoolean(),
                item.TryGetProperty("favorite", out var favorite) && favorite.GetBoolean(),
                names,
                turns,
                // The design review is the conversation the slides read: give it its sections and moments.
                id == "revision-onboarding"
                    ? [new(0, "Contexto", true), new(5, "Propuesta", true), new(9, "Decisión", false, "Probar con cinco usuarias"), new(13, "Próximos pasos", true)]
                    : null,
                item.TryGetProperty("fileName", out var file) ? file.GetString() : null));
        }
        return conversations;
    }

    /// <summary>Writes the conversations to the Library and returns them, with the favourites among them.</summary>
    public static async Task<IReadOnlyList<Recording>> SeedAsync(string libraryPath, IReadOnlyList<DemoConversation> conversations)
    {
        var staging = Path.Combine(Path.GetTempPath(), $"BardoDemo-{Guid.NewGuid()}");
        Directory.CreateDirectory(staging);
        using var recordings = new RecordingStore(libraryPath);
        using var transcripts = new TranscriptStore(libraryPath);
        var seeded = new List<Recording>();
        try
        {
            foreach (var conversation in conversations)
            {
                seeded.Add(await AddAsync(recordings, transcripts, staging, conversation).ConfigureAwait(false));
            }
        }
        finally
        {
            Directory.Delete(staging, recursive: true);
        }
        return seeded;
    }

    /// <summary>The recordings among <paramref name="seeded"/> marked as favourites.</summary>
    public static IEnumerable<Guid> Favorites(IReadOnlyList<DemoConversation> conversations, IReadOnlyList<Recording> seeded) =>
        conversations.Zip(seeded).Where(pair => pair.First.Favorite).Select(pair => pair.Second.Id);

    private static IReadOnlyList<DemoConversation> BuiltIn(DateTimeOffset now) =>
    [
        new("Revisión del diseño para Windows", now.AddHours(-2), DemoKind.Microphone, ProcessingState.Completed, Diarize: true, Favorite: false,
            new Dictionary<string, string> { ["valentina"] = "Valentina", ["diego"] = "Diego" },
            [
                ("valentina", "Partamos por la ventana principal. La barra lateral ya usa la navegación de Windows."),
                ("diego", "Bien. La búsqueda quedó en la barra de título, como en Outlook, y se abre con Control F."),
                ("valentina", "Lo que falta es la onda. En el Mac se nota quién habla en cada momento."),
                ("diego", "Podemos colorearla por participante, con el color de énfasis para la primera persona."),
                ("valentina", "Perfecto. Y en la grabación, que avance de derecha a izquierda como la Grabadora de sonido."),
                ("diego", "De acuerdo. Lo dejo listo para la próxima revisión y lo probamos en el PC."),
            ],
            [new(0, "Contexto", true), new(3, "Propuesta", true), new(4, "Decisión", false, "Colorear por participante")]),
        new("Llamada con el equipo", now.AddDays(-1).AddHours(-3), DemoKind.Meeting, ProcessingState.Completed, Diarize: false, Favorite: false,
            new Dictionary<string, string>(),
            [
                (LocalSpeaker, "Hola a todos, ¿me escuchan bien?"),
                ("equipo", "Sí, perfecto. Revisemos rápido los pendientes de la semana."),
                (LocalSpeaker, "Yo terminé la importación de audio y la papelera de reciclaje."),
                ("equipo", "Genial. Entonces queda la reproducción y probar la grabación del sistema."),
                (LocalSpeaker, "Lo pruebo mañana en el PC y les cuento."),
            ]),
        new("Entrevista con Ana", now.AddDays(-4), DemoKind.Imported, ProcessingState.Completed, Diarize: false, Favorite: false,
            new Dictionary<string, string>(),
            [
                ("ana", "Gracias por la invitación. Empecé a trabajar en audio hace casi diez años."),
                ("ana", "Lo que más me interesa es que las herramientas funcionen sin conexión y cuiden la privacidad."),
                ("ana", "Por eso me gusta que todo se procese en el propio equipo."),
            ]),
        new("Idea para el onboarding", now.AddDays(-15), DemoKind.Microphone, ProcessingState.Pending, Diarize: false, Favorite: true,
            new Dictionary<string, string>(),
            [(LocalSpeaker, "Una idea rápida para la primera pantalla: mostrar primero lo que Bardo hace sin conexión.")]),
    ];

    private static async Task<Recording> AddAsync(RecordingStore recordings, TranscriptStore transcripts, string staging, DemoConversation conversation)
    {
        var turns = Timed(conversation.Turns);
        var duration = turns.Count > 0 ? turns[^1].End + 1 : 5;
        var perTrack = conversation.Kind == DemoKind.Meeting;
        var speakerKeys = turns.Select(turn => turn.Speaker).Distinct().ToList();

        var tracks = new List<(AudioAssetRole Role, float[] Samples)>();
        switch (conversation.Kind)
        {
            case DemoKind.Meeting:
                var microphone = Synthesize(duration, turns, speakerKeys, turn => turn.Speaker == LocalSpeaker);
                var system = Synthesize(duration, turns, speakerKeys, turn => turn.Speaker != LocalSpeaker);
                tracks.Add((AudioAssetRole.MicrophoneOriginal, microphone));
                tracks.Add((AudioAssetRole.SystemOriginal, system));
                tracks.Add((AudioAssetRole.ConversationMix, [.. microphone.Zip(system, (left, right) => Math.Clamp(left + right, -1f, 1f))]));
                break;
            default:
                var role = conversation.Kind switch
                {
                    DemoKind.Microphone => AudioAssetRole.MicrophoneOriginal,
                    DemoKind.System => AudioAssetRole.SystemOriginal,
                    _ => AudioAssetRole.ImportedOriginal,
                };
                tracks.Add((role, Synthesize(duration, turns, speakerKeys, _ => true)));
                break;
        }

        var files = new Dictionary<Guid, string>();
        var assets = new List<AudioAsset>();
        foreach (var (role, samples) in tracks)
        {
            var path = Path.Combine(staging, $"{Guid.NewGuid()}.wav");
            WritePcm16(path, samples);
            var fileName = role == AudioAssetRole.ImportedOriginal && conversation.FileName is { } name ? Path.ChangeExtension(name, "wav") : $"{role}.wav";
            var asset = new AudioAsset(fileName, "wav", new AudioMetadata((double)samples.Length / SampleRate, "Linear PCM", SampleRate, 1), role,
                derivedFromAssetIds: role == AudioAssetRole.ConversationMix ? assets.Select(existing => existing.Id).ToEquatableArray() : default);
            assets.Add(asset);
            files[asset.Id] = path;
        }

        var notes = RecordingNotes.Empty;
        foreach (var mark in conversation.Marks ?? [])
        {
            if (mark.Turn >= turns.Count) continue;
            var time = turns[mark.Turn].Start;
            notes = mark.IsSection ? notes.AddingSection(time, mark.Title).Notes : notes.AddingMoment(time, mark.Title, mark.Note).Notes;
        }
        var sources = conversation.Kind switch
        {
            DemoKind.Meeting => new[] { AudioSource.Microphone, AudioSource.SystemAudio },
            DemoKind.Microphone => [AudioSource.Microphone],
            DemoKind.System => [AudioSource.SystemAudio],
            _ => [AudioSource.ImportedFile],
        };
        var recording = new Recording(conversation.Title, sources, conversation.CreatedAt, duration, conversation.State, assets.ToEquatableArray(), notes);
        await recordings.ImportRecordingAsync(recording, files).ConfigureAwait(false);
        if (conversation.State != ProcessingState.Completed) return recording;

        // Who is told apart: per track, you and the others (named when identified); on one
        // track, every voice once identified, and no one before.
        var speakers = new Dictionary<string, Speaker>();
        Speaker? others = null;
        foreach (var key in speakerKeys)
        {
            conversation.Names.TryGetValue(key, out var typed);
            var named = typed is { Length: > 0 } && typed != "Tú" ? typed : null;
            if (key == LocalSpeaker && (perTrack || conversation.Diarize))
            {
                speakers[key] = new Speaker(role: SpeakerRole.LocalUser);
            }
            else if (perTrack && !conversation.Diarize)
            {
                speakers[key] = others ??= new Speaker(role: SpeakerRole.Others);
            }
            else if (conversation.Diarize)
            {
                speakers[key] = new Speaker(named);
            }
        }
        var segments = turns.Select(turn => new TranscriptSegment(
            turn.Start, turn.End, turn.Text,
            speakerId: speakers.TryGetValue(turn.Speaker, out var speaker) ? speaker.Id : null,
            words: Words(turn),
            source: perTrack ? (turn.Speaker == LocalSpeaker ? TranscriptSource.Microphone : TranscriptSource.System) : null)).ToEquatableArray();
        await transcripts.SaveAsync(new Transcript(
            recording.Id,
            new TranscriptMetadata("Demo", "1", TranscriptionSelection.TurboModelId, new TranscriptionSelection(), conversation.CreatedAt,
                trackMode: perTrack ? TranscriptionTrackMode.PerTrack : null),
            "es",
            [.. speakers.Values.Distinct()],
            segments)).ConfigureAwait(false);
        return recording;
    }

    /// <summary>Each turn as long as it takes to say, with a breath between turns.</summary>
    private static List<Turn> Timed(IReadOnlyList<(string Speaker, string Text)> turns)
    {
        var timed = new List<Turn>();
        var time = 0.5;
        foreach (var (speaker, text) in turns)
        {
            var length = Math.Clamp(text.Length / 14.0, 2.5, 30);
            timed.Add(new Turn(speaker, time, time + length, text));
            time += length + 0.7;
        }
        return timed;
    }

    private static EquatableArray<TranscriptWord> Words(Turn turn)
    {
        var words = turn.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var step = (turn.End - turn.Start) / Math.Max(1, words.Length);
        return words.Select((word, index) => new TranscriptWord(turn.Start + index * step, turn.Start + (index + 1) * step, $" {word}", 0.95f)).ToEquatableArray();
    }

    /// <summary>
    /// Speech-like sound: syllables of a voiced tone with a little breath for each turn
    /// <paramref name="heard"/> says the track hears, silence elsewhere. Each speaker has a pitch.
    /// </summary>
    private static float[] Synthesize(double seconds, IReadOnlyList<Turn> turns, List<string> speakers, Func<Turn, bool> heard)
    {
        var samples = new float[(int)(seconds * SampleRate)];
        var random = new Random(turns.Count * 7919 + speakers.Count);
        foreach (var turn in turns.Where(heard))
        {
            var pitch = 110.0 + 35 * (speakers.IndexOf(turn.Speaker) % 4);
            var time = turn.Start;
            while (time < turn.End)
            {
                var length = 0.12 + random.NextDouble() * 0.16;
                var loudness = 0.08 + random.NextDouble() * 0.72;
                var start = (int)(time * SampleRate);
                var count = (int)(Math.Min(length, turn.End - time) * SampleRate);
                for (var index = 0; index < count && start + index < samples.Length; index++)
                {
                    var t = (double)index / SampleRate;
                    var envelope = Math.Sin(Math.PI * index / count);
                    var voice = Math.Sin(2 * Math.PI * pitch * t) + 0.5 * Math.Sin(4 * Math.PI * pitch * t) + 0.25 * Math.Sin(6 * Math.PI * pitch * t);
                    var breath = (random.NextDouble() * 2 - 1) * 0.15;
                    samples[start + index] = (float)(loudness * envelope * (voice / 1.75 + breath));
                }
                // Words run together; a sentence takes a breath.
                time += length + (random.NextDouble() < 0.15 ? 0.35 : 0.04);
            }
        }
        return samples;
    }

    private static void WritePcm16(string path, float[] samples)
    {
        using var stream = File.Create(path);
        Span<byte> header = stackalloc byte[44];
        "RIFF"u8.CopyTo(header);
        BinaryPrimitives.WriteInt32LittleEndian(header[4..], 36 + samples.Length * 2);
        "WAVEfmt "u8.CopyTo(header[8..]);
        BinaryPrimitives.WriteInt32LittleEndian(header[16..], 16);
        BinaryPrimitives.WriteInt16LittleEndian(header[20..], 1);
        BinaryPrimitives.WriteInt16LittleEndian(header[22..], 1);
        BinaryPrimitives.WriteInt32LittleEndian(header[24..], SampleRate);
        BinaryPrimitives.WriteInt32LittleEndian(header[28..], SampleRate * 2);
        BinaryPrimitives.WriteInt16LittleEndian(header[32..], 2);
        BinaryPrimitives.WriteInt16LittleEndian(header[34..], 16);
        "data"u8.CopyTo(header[36..]);
        BinaryPrimitives.WriteInt32LittleEndian(header[40..], samples.Length * 2);
        stream.Write(header);
        var data = new byte[samples.Length * 2];
        for (var index = 0; index < samples.Length; index++)
        {
            BinaryPrimitives.WriteInt16LittleEndian(data.AsSpan(index * 2), (short)(Math.Clamp(samples[index], -1f, 1f) * 32_000));
        }
        stream.Write(data);
    }
}

/// <summary>A recorder that records nothing: it plays back invented levels for design reviews.</summary>
public sealed class DemoCaptureService : ICaptureService
{
    public DemoSession? Session { get; private set; }

    public ICaptureSession Start(CaptureMode mode, string? microphoneDeviceId)
    {
        var kinds = mode switch
        {
            CaptureMode.Meeting => new[] { CaptureTrackKind.Microphone, CaptureTrackKind.SystemAudio },
            CaptureMode.SystemAudio => [CaptureTrackKind.SystemAudio],
            _ => [CaptureTrackKind.Microphone],
        };
        Session = new DemoSession(new CaptureManifest(
            Guid.NewGuid(), "", DateTimeOffset.UtcNow,
            [.. kinds.Select(kind => new CaptureTrack(Guid.NewGuid(), kind, $"{kind}.wav"))],
            RecordingNotes.Empty));
        return Session;
    }

    public Task<Recording?> PublishAsync(CaptureManifest manifest, AudioEncoding encoding, CancellationToken cancellationToken) =>
        Task.FromResult<Recording?>(null);

    public IReadOnlyList<CaptureManifest> Interrupted() => [];

    public void Discard(CaptureManifest manifest)
    {
    }

    /// <summary>Its clock moves only when told to, so a review can fill the waveform at once.</summary>
    public sealed class DemoSession(CaptureManifest manifest) : ICaptureSession
    {
        public CaptureManifest Manifest { get; private set; } = manifest;
        public double Elapsed { get; set; }
        public bool IsPaused { get; private set; }
        public bool IsMicrophoneMuted { get; set; }

        /// <summary>The microphone speaks in the first half of every eight seconds, the call in the second.</summary>
        public float MicrophoneLevel => Speech(Elapsed, speaking: Elapsed % 8 < 4);

        public float SystemLevel => Manifest.Tracks.Any(track => track.Kind == CaptureTrackKind.SystemAudio)
            ? Speech(Elapsed + 0.37, speaking: Elapsed % 8 >= 4)
            : 0;

        public void Pause() => IsPaused = true;

        public void Unpause() => IsPaused = false;

        public RecordingMoment AddMoment(string title, string? note)
        {
            var (notes, moment) = Manifest.Notes.AddingMoment(Elapsed, title, note);
            Manifest = Manifest with { Notes = notes };
            return moment;
        }

        public RecordingSection AddSection(string title)
        {
            var (notes, section) = Manifest.Notes.AddingSection(Elapsed, title);
            Manifest = Manifest with { Notes = notes };
            return section;
        }

        public Task<CaptureManifest> StopAsync() => Task.FromResult(Manifest);

        public void Dispose()
        {
        }

        private static float Speech(double time, bool speaking)
        {
            if (!speaking) return 0.002f;
            var syllable = Math.Abs(Math.Sin(time * 2 * Math.PI * 3.1));
            var phrase = 0.55 + 0.45 * Math.Sin(time * 2 * Math.PI * 0.23);
            return (float)(0.04 + 0.5 * syllable * phrase);
        }
    }
}
