using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Serialization;

namespace Bardo.Transcription;

/// <summary>One file to listen to and where it sits on the recording's timeline.</summary>
public sealed record TranscriptionPass(string Path, double Duration, double Offset, TranscriptSource? Source);

/// <summary>
/// What to listen to, in order. A recording transcribed per track is listened to twice:
/// the computer's audio first, so the microphone's echo of it can be recognised, then the
/// microphone.
/// </summary>
public sealed record TranscriptionPlan(
    EquatableArray<TranscriptionPass> Passes,
    double TimelineDuration,
    TranscriptionTrackMode? TrackMode)
{
    public bool IsPerTrack => TrackMode == TranscriptionTrackMode.PerTrack;
}

public static class TranscriptionAudioSelection
{
    public static bool IsDualCapture(Recording recording) =>
        recording.Sources.Contains(AudioSource.SystemAudio) && recording.Sources.Contains(AudioSource.Microphone);

    /// <summary>
    /// The original tracks to transcribe apart, computer's audio first so the microphone's
    /// echo of it can be recognised; null when the recording is not a dual capture, the
    /// mix was chosen, or an original is missing.
    /// </summary>
    public static (AudioAsset System, AudioAsset Microphone)? SeparateTracks(Recording recording, TranscriptionTrackMode mode)
    {
        if (mode != TranscriptionTrackMode.PerTrack || !IsDualCapture(recording)) return null;
        var system = recording.AudioAssets.FirstOrDefault(asset => asset.Role == AudioAssetRole.SystemOriginal);
        var microphone = recording.AudioAssets.FirstOrDefault(asset => asset.Role == AudioAssetRole.MicrophoneOriginal);
        return system is not null && microphone is not null ? (system, microphone) : null;
    }

    /// <summary>
    /// The single track to transcribe, best first. A dual capture is only ever transcribed
    /// from its conversation mix, never from one of its originals alone.
    /// </summary>
    public static IReadOnlyList<AudioAsset> Candidates(Recording recording) =>
        IsDualCapture(recording)
            ? [.. recording.AudioAssets.Where(asset => asset.Role == AudioAssetRole.ConversationMix)]
            : recording.PlaybackAudioAssets;

    /// <summary>
    /// What to listen to: both original tracks apart when asked and both are readable,
    /// otherwise the single track Bardo has always transcribed.
    /// </summary>
    /// <exception cref="TranscriptionException">No readable audio, or no valid duration.</exception>
    public static async Task<TranscriptionPlan> ResolvePlanAsync(
        Recording recording,
        RecordingStore store,
        TranscriptionTrackMode trackMode)
    {
        if (SeparateTracks(recording, trackMode) is { } tracks
            && await ReadablePathAsync(recording, tracks.System, store).ConfigureAwait(false) is { } system
            && await ReadablePathAsync(recording, tracks.Microphone, store).ConfigureAwait(false) is { } microphone
            && tracks.System.Metadata.Duration > 0
            && tracks.Microphone.Metadata.Duration > 0)
        {
            TranscriptionPass[] passes =
            [
                new(system, tracks.System.Metadata.Duration, tracks.System.TimelineOffset, TranscriptSource.System),
                new(microphone, tracks.Microphone.Metadata.Duration, tracks.Microphone.TimelineOffset, TranscriptSource.Microphone),
            ];
            var timeline = recording.Duration ?? passes.Max(pass => pass.Offset + pass.Duration);
            return Validated(new TranscriptionPlan(passes, timeline, TranscriptionTrackMode.PerTrack));
        }

        var candidates = Candidates(recording);
        var isDualCapture = IsDualCapture(recording);
        if (isDualCapture && candidates.Count == 0) throw TranscriptionException.CombinedAudioUnavailable(recording.Id);
        if (await FirstReadableAsync(recording, candidates, store).ConfigureAwait(false) is not { } readable)
        {
            throw isDualCapture
                ? TranscriptionException.CombinedAudioUnavailable(recording.Id)
                : TranscriptionException.NoManagedAudio(recording.Id);
        }
        return Validated(new TranscriptionPlan(
            [new TranscriptionPass(readable.Path, readable.Duration, 0, null)],
            readable.Duration,
            isDualCapture ? TranscriptionTrackMode.Mix : null));
    }

    /// <summary>The first candidate whose file is readable and whose duration is known.</summary>
    internal static async Task<(string Path, double Duration)?> FirstReadableAsync(
        Recording recording,
        IEnumerable<AudioAsset> candidates,
        RecordingStore store)
    {
        foreach (var asset in candidates)
        {
            if (await ReadablePathAsync(recording, asset, store).ConfigureAwait(false) is not { } path) continue;
            var duration = asset.Metadata.Duration;
            if (double.IsFinite(duration) && duration > 0) return (path, duration);
        }
        return null;
    }

    private static async Task<string?> ReadablePathAsync(Recording recording, AudioAsset asset, RecordingStore store)
    {
        try
        {
            return await store.ManagedAudioPathAsync(recording.Id, asset.Id).ConfigureAwait(false);
        }
        catch (Exception error) when (error is RecordingStoreException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static TranscriptionPlan Validated(TranscriptionPlan plan) =>
        double.IsFinite(plan.TimelineDuration) && plan.TimelineDuration > 0
            ? plan
            : throw TranscriptionException.InvalidDuration();
}
