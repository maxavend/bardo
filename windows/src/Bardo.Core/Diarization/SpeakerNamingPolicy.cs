using Bardo.Domain;

namespace Bardo.Diarization;

/// <summary>What the transcript offers about its speakers.</summary>
public abstract record SpeakerNamingPresentation
{
    private SpeakerNamingPresentation()
    {
    }

    /// <summary>Speakers are not told apart yet.</summary>
    public sealed record IdentifySpeakers : SpeakerNamingPresentation;

    /// <summary>One voice: nothing to name.</summary>
    public sealed record SingleSpeaker : SpeakerNamingPresentation;

    /// <summary>Several participants that can be named.</summary>
    public sealed record Participants(int Count) : SpeakerNamingPresentation;
}

public static class SpeakerNamingPolicy
{
    public static SpeakerNamingPresentation Presentation(Transcript transcript)
    {
        // Tracks transcribed apart already separate "You" from "Others"; the others are
        // still one voice until their participants are told apart.
        if (transcript.DiarizationMetadata is null && transcript.Speakers.Any(speaker => speaker.Role == SpeakerRole.Others))
        {
            return new SpeakerNamingPresentation.IdentifySpeakers();
        }
        return transcript.Speakers.Count switch
        {
            0 => new SpeakerNamingPresentation.IdentifySpeakers(),
            1 => new SpeakerNamingPresentation.SingleSpeaker(),
            var count => new SpeakerNamingPresentation.Participants(count),
        };
    }

    public static bool ShouldOpenNamingFlow(Transcript transcript) => transcript.Speakers.Count >= 2;
}
