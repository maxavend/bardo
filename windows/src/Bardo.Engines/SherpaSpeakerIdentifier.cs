using Bardo.Diarization;
using Bardo.Domain;
using Bardo.Library;
using Bardo.Persistence;
using SherpaOnnx;

namespace Bardo.Engines;

/// <summary>
/// Tells voices apart with sherpa-onnx: pyannote segmentation finds where voices change,
/// TitaNet compares them, and Bardo's aligner gives each word its speaker. The whole file
/// is heard at once so a speaker keeps one identity throughout.
/// </summary>
public sealed class SherpaSpeakerIdentifier(string segmentationModelPath, string embeddingModelPath, RecordingStore store, IAudioDecoder decoder)
    : ISpeakerIdentifier, IDisposable
{
    public const string EngineName = "sherpa-onnx";
    public const string EngineVersion = "1.13.8";
    public const string ModelId = "pyannote-segmentation-3.0+nemo-titanet-small";

    /// <summary>Voices whose embeddings are closer than this are the same person.</summary>
    public const float ClusteringThreshold = 0.5f;

    /// <summary>Silences shorter than this between two voices are split between them.</summary>
    public const double ClosableGap = 2.0;

    private readonly SemaphoreSlim _gate = new(1, 1);

    public async Task<Transcript> IdentifySpeakersAsync(Recording recording, Transcript transcript, IProgress<WorkProgress> progress, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var started = DateTimeOffset.UtcNow;
            var audio = await DiarizationAudio.ResolveAsync(recording, transcript, store).ConfigureAwait(false);
            var samples = new List<float>();
            await foreach (var chunk in decoder.ReadMonoAsync(audio.Path, 16_000, TimeSpan.FromMinutes(10), cancellationToken).ConfigureAwait(false))
            {
                samples.AddRange(chunk);
            }

            var turns = await Task.Run(() => Diarize([.. samples], progress, cancellationToken), cancellationToken).ConfigureAwait(false);
            var metadata = new DiarizationMetadata(EngineName, EngineVersion, ModelId, DateTimeOffset.UtcNow, (DateTimeOffset.UtcNow - started).TotalSeconds);
            return TranscriptSpeakerAligner.Identify(transcript, audio, turns, metadata);
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose() => _gate.Dispose();

    private IReadOnlyList<SpeakerTurn> Diarize(float[] samples, IProgress<WorkProgress> progress, CancellationToken cancellationToken)
    {
        var config = new OfflineSpeakerDiarizationConfig();
        config.Segmentation.Pyannote.Model = segmentationModelPath;
        config.Segmentation.NumThreads = Math.Max(1, Environment.ProcessorCount / 2);
        config.Embedding.Model = embeddingModelPath;
        config.Embedding.NumThreads = Math.Max(1, Environment.ProcessorCount / 2);
        config.Clustering.NumClusters = -1;
        config.Clustering.Threshold = ClusteringThreshold;
        config.MinDurationOn = 0.3f;
        config.MinDurationOff = 0.5f;

        using var diarization = new OfflineSpeakerDiarization(config);
        // Returning non-zero from the callback stops sherpa-onnx early.
        OfflineSpeakerDiarizationProgressCallback callback = (done, total, _) =>
        {
            progress.Report(new WorkProgress(total > 0 ? (double)done / total : 0));
            return cancellationToken.IsCancellationRequested ? 1 : 0;
        };
        var segments = diarization.ProcessWithCallback(samples, callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        cancellationToken.ThrowIfCancellationRequested();
        return ClosingGaps([.. segments.Select(segment => new SpeakerTurn(segment.Speaker, segment.Start, segment.End))]);
    }

    /// <summary>
    /// Whisper's word times are estimates and can start a little before the voice does. A
    /// short silence between two turns is split at its middle, so a word said at its edge
    /// still finds its speaker.
    /// </summary>
    internal static IReadOnlyList<SpeakerTurn> ClosingGaps(IReadOnlyList<SpeakerTurn> turns)
    {
        var sorted = turns.OrderBy(turn => turn.StartTime).ToList();
        for (var index = 1; index < sorted.Count; index++)
        {
            var previous = sorted[index - 1];
            var next = sorted[index];
            var gap = next.StartTime - previous.EndTime;
            if (gap <= 0 || gap >= ClosableGap) continue;
            var middle = previous.EndTime + gap / 2;
            sorted[index - 1] = previous with { EndTime = middle };
            sorted[index] = next with { StartTime = middle };
        }
        return sorted;
    }
}
