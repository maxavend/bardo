namespace Bardo.Transcription;

/// <summary>
/// How much audio Whisper holds and how many windows it decodes at once, sized by the
/// computer's memory.
/// </summary>
public sealed record WhisperPerformanceProfile
{
    public const ulong SixteenGigabyteThreshold = 16UL * 1_024 * 1_024 * 1_024;

    public WhisperPerformanceProfile(ulong physicalMemory)
    {
        PhysicalMemory = physicalMemory;
        if (physicalMemory >= SixteenGigabyteThreshold)
        {
            IncrementalChunkDurationSeconds = 120;
            MaxBufferedChunks = 2;
            ConcurrentWorkerCount = 8;
        }
        else
        {
            IncrementalChunkDurationSeconds = 90;
            MaxBufferedChunks = 1;
            ConcurrentWorkerCount = 4;
        }
        UsesVad = true;
        TemperatureFallbackCount = 5;
    }

    public ulong PhysicalMemory { get; }

    /// <summary>Audio is read this many seconds at a time, so a long meeting never sits whole in memory.</summary>
    public double IncrementalChunkDurationSeconds { get; }

    public int MaxBufferedChunks { get; }
    public int ConcurrentWorkerCount { get; }

    /// <summary>Windows are cut at silences found by voice activity detection, not every 30 s.</summary>
    public bool UsesVad { get; }

    public int TemperatureFallbackCount { get; }

    /// <summary>The profile for this computer, from the memory the runtime can use.</summary>
    public static WhisperPerformanceProfile Current() =>
        new((ulong)Math.Max(0, GC.GetGCMemoryInfo().TotalAvailableMemoryBytes));
}

/// <summary>
/// Decoding settings for every transcription, whatever runs Whisper. Bardo keeps
/// Whisper's own defaults except where noted.
/// </summary>
/// <remarks>
/// No prompt: conditioning the decoder on a vocabulary prompt made Whisper skip the
/// opening of each window and shift every later timestamp (a 25 s Spanish conversation
/// lost its first 13 s). Product terms are normalized after recognition by
/// <c>TranscriptTextSanitizer</c> instead.
/// </remarks>
public sealed record WhisperDecodingSettings
{
    /// <summary>
    /// A window whose text compresses this well is a repetition loop. Whisper's default
    /// (2.4) also flags ordinary conversation that repeats a phrase; the temperature
    /// fallback it then triggers dropped whole turns at random (2–13 of 24 turns in a
    /// 187 s test dialogue). Real loops compress far beyond 3.5. This is the gzip
    /// compression ratio of the decoded text, as in OpenAI's Whisper.
    /// </summary>
    public const float RepetitionCompressionRatioThreshold = 3.5f;

    public const float DefaultTemperature = 0;
    public const float DefaultTemperatureIncrementOnFallback = 0.2f;
    public const float DefaultLogProbThreshold = -1.0f;
    public const float DefaultFirstTokenLogProbThreshold = -1.5f;
    public const float DefaultNoSpeechThreshold = 0.6f;

    public float Temperature { get; init; } = DefaultTemperature;
    public float TemperatureIncrementOnFallback { get; init; } = DefaultTemperatureIncrementOnFallback;
    public int TemperatureFallbackCount { get; init; }
    public float CompressionRatioThreshold { get; init; } = RepetitionCompressionRatioThreshold;

    /// <summary>Low-confidence windows still fall back to a higher temperature.</summary>
    public float LogProbThreshold { get; init; } = DefaultLogProbThreshold;

    public float FirstTokenLogProbThreshold { get; init; } = DefaultFirstTokenLogProbThreshold;
    public float NoSpeechThreshold { get; init; } = DefaultNoSpeechThreshold;

    /// <summary>Always null: see the remarks on why Bardo never prompts the decoder.</summary>
    public string? Prompt { get; }

    /// <summary>Null to detect the language from the audio.</summary>
    public string? Language { get; init; }

    public bool DetectLanguage { get; init; } = true;
    public bool UsePrefillPrompt { get; init; } = true;
    public bool SkipSpecialTokens { get; init; } = true;

    /// <summary>Seeking and karaoke need word timings.</summary>
    public bool WordTimestamps { get; init; } = true;

    public int ConcurrentWorkerCount { get; init; }
    public bool UsesVad { get; init; }

    public static WhisperDecodingSettings For(WhisperPerformanceProfile profile) => new()
    {
        TemperatureFallbackCount = profile.TemperatureFallbackCount,
        ConcurrentWorkerCount = profile.ConcurrentWorkerCount,
        UsesVad = profile.UsesVad,
    };

    /// <summary>
    /// The settings for the microphone, decoded in the conversation's language: a quiet
    /// echo is otherwise easily taken for English and translated.
    /// </summary>
    public WhisperDecodingSettings InLanguage(string? language) =>
        language is null ? this : this with { Language = language, DetectLanguage = false };
}
