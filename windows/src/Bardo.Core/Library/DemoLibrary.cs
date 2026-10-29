using System.Buffers.Binary;
using Bardo.Capture;
using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Serialization;

namespace Bardo.Library;

/// <summary>
/// A made-up Library for design reviews and screenshots: four conversations with invented
/// people, speech-like audio and transcripts, so nothing private is ever shown.
/// </summary>
public static class DemoLibrary
{
    public const int SampleRate = 16_000;

    private sealed record Turn(int Voice, double Start, double End, string Text);

    public static async Task<IReadOnlyList<Recording>> SeedAsync(string libraryPath, DateTimeOffset now)
    {
        var staging = Path.Combine(Path.GetTempPath(), $"BardoDemo-{Guid.NewGuid()}");
        Directory.CreateDirectory(staging);
        using var recordings = new RecordingStore(libraryPath);
        using var transcripts = new TranscriptStore(libraryPath);
        var seeded = new List<Recording>();
        try
        {
            // A design review in a room: one microphone, two people told apart.
            var reviewTurns = new Turn[]
            {
                new(0, 0.5, 9.5, "Partamos por la ventana principal. La barra lateral ya usa la navegación de Windows."),
                new(1, 10.2, 21.0, "Bien. La búsqueda quedó en la barra de título, como en Outlook, y se abre con Control F."),
                new(0, 22.0, 33.5, "Lo que falta es la onda. En el Mac se nota quién habla en cada momento."),
                new(1, 34.5, 47.0, "Podemos colorearla por participante, con el color de énfasis para la primera persona."),
                new(0, 48.0, 58.5, "Perfecto. Y en la grabación, que avance de derecha a izquierda como la Grabadora de sonido."),
                new(1, 59.5, 72.0, "De acuerdo. Lo dejo listo para la próxima revisión y lo probamos en el PC."),
            };
            var review = await AddAsync(
                recordings, transcripts, staging,
                "Revisión del diseño para Windows", now.AddHours(-2), [AudioSource.Microphone],
                [(AudioAssetRole.MicrophoneOriginal, Synthesize(74, reviewTurns, track: null))],
                reviewTurns, speakerNames: ["Valentina", "Diego"], perTrack: false,
                notes: RecordingNotes.Empty
                    .AddingSection(0, "Contexto").Notes
                    .AddingSection(34, "Propuesta").Notes
                    .AddingMoment(58, "Decisión", "Colorear por participante").Notes).ConfigureAwait(false);
            seeded.Add(review);

            // A call: the microphone and the computer's audio, transcribed per track.
            var callTurns = new Turn[]
            {
                new(0, 0.5, 6.5, "Hola a todos, ¿me escuchan bien?"),
                new(1, 7.2, 15.0, "Sí, perfecto. Revisemos rápido los pendientes de la semana."),
                new(0, 16.0, 24.5, "Yo terminé la importación de audio y la papelera de reciclaje."),
                new(1, 25.5, 36.0, "Genial. Entonces queda la reproducción y probar la grabación del sistema."),
                new(0, 37.0, 43.0, "Lo pruebo mañana en el PC y les cuento."),
            };
            var microphone = Synthesize(45, callTurns, track: 0);
            var system = Synthesize(45, callTurns, track: 1);
            var mix = microphone.Zip(system, (left, right) => Math.Clamp(left + right, -1f, 1f)).ToArray();
            seeded.Add(await AddAsync(
                recordings, transcripts, staging,
                "Llamada con el equipo", now.AddDays(-1).AddHours(-3), [AudioSource.Microphone, AudioSource.SystemAudio],
                [(AudioAssetRole.MicrophoneOriginal, microphone), (AudioAssetRole.SystemOriginal, system), (AudioAssetRole.ConversationMix, mix)],
                callTurns, speakerNames: [], perTrack: true, notes: RecordingNotes.Empty).ConfigureAwait(false));

            // An imported interview, transcribed but not yet told apart.
            var interviewTurns = new Turn[]
            {
                new(1, 0.5, 12.0, "Gracias por la invitación. Empecé a trabajar en audio hace casi diez años."),
                new(1, 13.0, 26.0, "Lo que más me interesa es que las herramientas funcionen sin conexión y cuiden la privacidad."),
                new(1, 27.0, 38.0, "Por eso me gusta que todo se procese en el propio equipo."),
            };
            seeded.Add(await AddAsync(
                recordings, transcripts, staging,
                "Entrevista con Ana", now.AddDays(-4), [AudioSource.ImportedFile],
                [(AudioAssetRole.ImportedOriginal, Synthesize(40, interviewTurns, track: null))],
                interviewTurns, speakerNames: null, perTrack: false, notes: RecordingNotes.Empty).ConfigureAwait(false));

            // A voice memo, not transcribed yet.
            var memoTurns = new Turn[] { new(0, 0.5, 14.0, "") };
            seeded.Add(await AddAsync(
                recordings, transcripts, staging,
                "Idea para el onboarding", now.AddDays(-15), [AudioSource.Microphone],
                [(AudioAssetRole.MicrophoneOriginal, Synthesize(15, memoTurns, track: null))],
                memoTurns, speakerNames: null, perTrack: false, notes: RecordingNotes.Empty, transcribed: false).ConfigureAwait(false));
        }
        finally
        {
            Directory.Delete(staging, recursive: true);
        }
        return seeded;
    }

    private static async Task<Recording> AddAsync(
        RecordingStore recordings,
        TranscriptStore transcripts,
        string staging,
        string title,
        DateTimeOffset createdAt,
        IReadOnlyList<AudioSource> sources,
        IReadOnlyList<(AudioAssetRole Role, float[] Samples)> tracks,
        IReadOnlyList<Turn> turns,
        IReadOnlyList<string>? speakerNames,
        bool perTrack,
        RecordingNotes notes,
        bool transcribed = true)
    {
        var files = new Dictionary<Guid, string>();
        var assets = new List<AudioAsset>();
        foreach (var (role, samples) in tracks)
        {
            var path = Path.Combine(staging, $"{Guid.NewGuid()}.wav");
            WritePcm16(path, samples);
            var duration = (double)samples.Length / SampleRate;
            var asset = new AudioAsset($"{role}.wav", "wav", new AudioMetadata(duration, "Linear PCM", SampleRate, 1), role,
                derivedFromAssetIds: role == AudioAssetRole.ConversationMix ? assets.Select(existing => existing.Id).ToEquatableArray() : default);
            assets.Add(asset);
            files[asset.Id] = path;
        }
        var recording = new Recording(
            title, sources, createdAt, assets.Max(asset => asset.Metadata.Duration),
            transcribed ? ProcessingState.Completed : ProcessingState.Pending,
            assets.ToEquatableArray(), notes);
        await recordings.ImportRecordingAsync(recording, files).ConfigureAwait(false);
        if (!transcribed) return recording;

        EquatableArray<Speaker> speakers = perTrack
            ? [new Speaker(role: SpeakerRole.LocalUser), new Speaker(role: SpeakerRole.Others)]
            : speakerNames is { Count: > 0 } names ? [.. names.Select(name => new Speaker(name))] : [];
        var segments = turns.Select(turn => new TranscriptSegment(
            turn.Start, turn.End, turn.Text,
            speakerId: speakers.Count > 0 ? speakers[Math.Min(turn.Voice, speakers.Count - 1)].Id : null,
            words: Words(turn),
            source: perTrack ? (turn.Voice == 0 ? TranscriptSource.Microphone : TranscriptSource.System) : null)).ToEquatableArray();
        await transcripts.SaveAsync(new Transcript(
            recording.Id,
            new TranscriptMetadata("Demo", "1", TranscriptionSelection.TurboModelId, new TranscriptionSelection(), createdAt,
                trackMode: perTrack ? TranscriptionTrackMode.PerTrack : null),
            "es", speakers, segments)).ConfigureAwait(false);
        return recording;
    }

    private static EquatableArray<TranscriptWord> Words(Turn turn)
    {
        var words = turn.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var step = (turn.End - turn.Start) / Math.Max(1, words.Length);
        return words.Select((word, index) => new TranscriptWord(turn.Start + index * step, turn.Start + (index + 1) * step, $" {word}", 0.95f)).ToEquatableArray();
    }

    /// <summary>
    /// Speech-like sound: syllables of a voiced tone with a little breath, in each turn of
    /// <paramref name="track"/> (or every turn when null), silence elsewhere.
    /// </summary>
    private static float[] Synthesize(double seconds, IReadOnlyList<Turn> turns, int? track)
    {
        var samples = new float[(int)(seconds * SampleRate)];
        var random = new Random(turns.Count * 7919 + (track ?? 3));
        foreach (var turn in turns.Where(turn => track is null || turn.Voice == track))
        {
            var pitch = turn.Voice == 0 ? 210.0 : 125.0;
            var time = turn.Start;
            while (time < turn.End)
            {
                var length = 0.12 + random.NextDouble() * 0.16;
                var loudness = 0.25 + random.NextDouble() * 0.55;
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
