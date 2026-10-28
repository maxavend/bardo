using Bardo.Domain;
using Bardo.Library;
using Bardo.Persistence;
using Bardo.Settings;
using Bardo.Transcription;
using Whisper.net;

namespace Bardo.Engines;

/// <summary>
/// Transcribes with Whisper through whisper.cpp (Whisper.net): on the GPU through Vulkan
/// where there is one, otherwise on the CPU. A recording with a microphone and system
/// track is transcribed per track, system first, as on macOS.
/// </summary>
public sealed class WhisperTranscriber : ITranscriber, IDisposable
{
    public const string EngineName = "Whisper.net";
    public const string EngineVersion = "1.9.1";
    public const int SampleRate = 16_000;

    /// <summary>Whisper.net takes the audio a stretch at a time, so a long recording never sits in memory whole.</summary>
    private static readonly TimeSpan ChunkLength = TimeSpan.FromMinutes(10);

    private readonly string _modelPath;
    private readonly TranscriptionQuality _quality;
    private readonly RecordingStore _store;
    private readonly IAudioDecoder _decoder;
    private readonly Func<TranscriptionTrackMode> _trackMode;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private WhisperFactory? _factory;

    public WhisperTranscriber(string modelPath, TranscriptionQuality quality, RecordingStore store, IAudioDecoder decoder, Func<TranscriptionTrackMode> trackMode)
    {
        _modelPath = modelPath;
        _quality = quality;
        _store = store;
        _decoder = decoder;
        _trackMode = trackMode;
    }

    public async Task<Transcript> TranscribeAsync(Recording recording, IProgress<WorkProgress> progress, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var started = DateTimeOffset.UtcNow;
            var plan = await TranscriptionAudioSelection.ResolvePlanAsync(recording, _store, _trackMode()).ConfigureAwait(false);
            var factory = await Task.Run(Factory, cancellationToken).ConfigureAwait(false);

            var totalDuration = plan.Passes.Sum(pass => pass.Duration);
            double doneBefore = 0;
            string? language = null;
            var languages = new List<string>();
            var segmentsPerPass = new List<IReadOnlyList<TranscriptSegment>>();
            foreach (var pass in plan.Passes)
            {
                var recognized = new List<RecognizedSegment>();
                var passStart = doneBefore;
                await foreach (var segment in RecognizeAsync(factory, pass.Path, language, seconds =>
                    progress.Report(new WorkProgress((passStart + seconds) / Math.Max(1, totalDuration))), cancellationToken).ConfigureAwait(false))
                {
                    recognized.Add(segment.Segment);
                    if (segment.Language is { Length: > 0 } detected) languages.Add(detected);
                }
                segmentsPerPass.Add(TranscriptionAssembly.Segments(recognized, pass));
                doneBefore += pass.Duration;
                // The microphone is heard in the language the call was in.
                language ??= MostCommon(languages);
            }

            var (segments, speakers) = TranscriptionAssembly.Combine(plan, segmentsPerPass);
            var selection = new TranscriptionSelection(
                TranscriptionBackend.WhisperKit,
                _quality == TranscriptionQuality.Precise ? TranscriptionSelection.LargeModelId : TranscriptionSelection.TurboModelId);
            return new Transcript(
                recording.Id,
                new TranscriptMetadata(
                    EngineName,
                    EngineVersion,
                    Path.GetFileNameWithoutExtension(_modelPath),
                    selection,
                    DateTimeOffset.UtcNow,
                    (DateTimeOffset.UtcNow - started).TotalSeconds,
                    plan.TrackMode),
                MostCommon(languages),
                speakers,
                segments);
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose()
    {
        _factory?.Dispose();
        _gate.Dispose();
    }

    /// <summary>
    /// Without dynamic time warping: with it, whisper.cpp 1.9.1 stopped after the first 30 s
    /// window and dropped the rest of a 44 s dialogue.
    /// </summary>
    private WhisperFactory Factory() => _factory ??= WhisperFactory.FromPath(_modelPath);

    private async IAsyncEnumerable<(RecognizedSegment Segment, string? Language)> RecognizeAsync(
        WhisperFactory factory,
        string path,
        string? language,
        Action<double> heard,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        double offset = 0;
        await foreach (var chunk in _decoder.ReadMonoAsync(path, SampleRate, ChunkLength, cancellationToken).ConfigureAwait(false))
        {
            await using var processor = Builder(factory, language).Build();
            await foreach (var segment in processor.ProcessAsync(chunk, cancellationToken).ConfigureAwait(false))
            {
                yield return (WhisperSegments.Recognized(segment, offset), segment.Language);
                heard(offset + segment.End.TotalSeconds);
            }
            offset += (double)chunk.Length / SampleRate;
            heard(offset);
        }
    }

    /// <summary>The decoding Bardo uses on macOS: no prompt, greedy at 0 with temperature fallback, word timings.</summary>
    private static WhisperProcessorBuilder Builder(WhisperFactory factory, string? language) => factory.CreateBuilder()
        .WithLanguage(language ?? "auto")
        .WithThreads(Math.Max(1, Environment.ProcessorCount - 1))
        .WithTokenTimestamps()
        .WithProbabilities()
        .WithTemperature(WhisperDecodingSettings.DefaultTemperature)
        .WithTemperatureInc(WhisperDecodingSettings.DefaultTemperatureIncrementOnFallback)
        .WithLogProbThreshold(WhisperDecodingSettings.DefaultLogProbThreshold)
        .WithNoSpeechThreshold(WhisperDecodingSettings.DefaultNoSpeechThreshold);

    private static string? MostCommon(IEnumerable<string> values) =>
        values.GroupBy(value => value).OrderByDescending(group => group.Count()).Select(group => group.Key).FirstOrDefault();
}

/// <summary>Whisper.net output in Bardo's engine-neutral terms.</summary>
internal static class WhisperSegments
{
    /// <summary>
    /// The segment's words, rebuilt from tokens: a token that starts with a space starts a
    /// word, and special and timestamp tokens are dropped. Times are seconds, offset by
    /// where the chunk began.
    /// </summary>
    public static RecognizedSegment Recognized(SegmentData segment, double offset)
    {
        var start = offset + segment.Start.TotalSeconds;
        var end = Math.Max(start, offset + segment.End.TotalSeconds);
        var words = new List<(string Text, double Start, float Probability, int Tokens)>();
        foreach (var token in segment.Tokens ?? [])
        {
            var text = token.Text ?? "";
            if (text.Length == 0 || text.StartsWith("[_", StringComparison.Ordinal) || text.StartsWith("<|", StringComparison.Ordinal)) continue;
            var time = Math.Clamp(offset + token.Start / 100.0, start, end);
            if (words.Count == 0 || text.StartsWith(' '))
            {
                words.Add((text, time, token.Probability, 1));
            }
            else
            {
                var last = words[^1];
                words[^1] = (last.Text + text, last.Start, last.Probability + token.Probability, last.Tokens + 1);
            }
        }

        var starts = words.Select(word => word.Start).ToList();
        // whisper.cpp often gives most tokens of a segment the same time; then the words
        // share the segment's length by how long each is to say.
        if (starts.Distinct().Count() < Math.Max(2, words.Count / 2))
        {
            var length = Math.Max(1, words.Sum(word => word.Text.Trim().Length));
            var position = start;
            for (var index = 0; index < words.Count; index++)
            {
                starts[index] = position;
                position += (end - start) * Math.Max(1, words[index].Text.Trim().Length) / length;
            }
        }

        var recognizedWords = words.Select((word, index) => new RecognizedWord(
            starts[index],
            index + 1 < words.Count ? Math.Max(starts[index], starts[index + 1]) : end,
            word.Text,
            word.Probability / word.Tokens)).ToList();
        return new RecognizedSegment(start, end, segment.Text ?? "", [.. recognizedWords]);
    }
}
