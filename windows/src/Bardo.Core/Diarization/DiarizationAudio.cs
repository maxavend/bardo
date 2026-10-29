using Bardo.Domain;
using Bardo.Persistence;
using Bardo.Transcription;

namespace Bardo.Diarization;

/// <summary>
/// The file speaker identification listens to, whole, and where it sits on the recording's
/// timeline. Inference runs over the full file so a voice keeps one identity throughout.
/// </summary>
public sealed record DiarizationAudio(string Path, double Duration, double TimelineOffset, bool IsOthersTrack)
{
    /// <summary>
    /// A transcript made per track already knows the microphone is the person recording,
    /// so only the computer's audio needs its participants told apart; otherwise the
    /// track Bardo transcribes.
    /// </summary>
    /// <exception cref="DiarizationException">No readable audio, or no valid duration.</exception>
    public static async Task<DiarizationAudio> ResolveAsync(Recording recording, Transcript transcript, RecordingStore store)
    {
        var othersTrack = transcript.IsPerTrack
            ? recording.AudioAssets.FirstOrDefault(asset => asset.Role == AudioAssetRole.SystemOriginal)
            : null;

        DiarizationAudio audio;
        if (othersTrack is not null)
        {
            var path = await store.ManagedAudioPathAsync(recording.Id, othersTrack.Id).ConfigureAwait(false);
            audio = new DiarizationAudio(path, othersTrack.Metadata.Duration, othersTrack.TimelineOffset, IsOthersTrack: true);
        }
        else
        {
            var candidates = TranscriptionAudioSelection.Candidates(recording);
            var isDualCapture = TranscriptionAudioSelection.IsDualCapture(recording);
            if (isDualCapture && candidates.Count == 0) throw DiarizationException.CombinedAudioUnavailable(recording.Id);
            var found = await TranscriptionAudioSelection.FirstReadableAsync(recording, candidates, store).ConfigureAwait(false);
            if (found is not { } readable)
            {
                throw isDualCapture
                    ? DiarizationException.CombinedAudioUnavailable(recording.Id)
                    : DiarizationException.NoManagedAudio(recording.Id);
            }
            audio = new DiarizationAudio(readable.Path, readable.Duration, 0, IsOthersTrack: false);
        }

        if (!double.IsFinite(audio.Duration) || audio.Duration <= 0) throw DiarizationException.InvalidDuration();
        return audio;
    }
}
