using Bardo.Domain;

namespace Bardo.Library;

/// <summary>How far a transcription or speaker identification has got, from 0 to 1.</summary>
public readonly record struct WorkProgress(double Fraction, string? Stage = null);

/// <summary>Turns a recording's audio into a transcript. Implemented with Whisper on Windows.</summary>
public interface ITranscriber
{
    Task<Transcript> TranscribeAsync(Recording recording, IProgress<WorkProgress> progress, CancellationToken cancellationToken);
}

/// <summary>Tells the voices of a transcript apart. Implemented with sherpa-onnx on Windows.</summary>
public interface ISpeakerIdentifier
{
    Task<Transcript> IdentifySpeakersAsync(Recording recording, Transcript transcript, IProgress<WorkProgress> progress, CancellationToken cancellationToken);
}

/// <summary>Decodes an audio file to mono samples at a given rate, a stretch at a time, for the recognisers.</summary>
public interface IAudioDecoder
{
    IAsyncEnumerable<float[]> ReadMonoAsync(string path, int sampleRate, TimeSpan chunkLength, CancellationToken cancellationToken);
}
