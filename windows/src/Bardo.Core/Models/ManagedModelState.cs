namespace Bardo.Models;

/// <summary>The local models Bardo downloads and can remove.</summary>
public enum ManagedModel
{
    WhisperTurbo,
    WhisperLarge,
    SpeakerIdentification,
}

public abstract record ManagedModelState
{
    private ManagedModelState()
    {
    }

    public sealed record NotInstalled : ManagedModelState;

    public sealed record Downloading(double Fraction) : ManagedModelState;

    public sealed record Preparing(double Fraction) : ManagedModelState;

    public sealed record Installed : ManagedModelState;

    public sealed record Failed(string Message) : ManagedModelState;
}

public enum ModelSetupStage
{
    Checking,
    Downloading,

    /// <summary>Loading the model and getting it ready for this computer's hardware.</summary>
    Optimizing,
}

public sealed record ModelSetupProgressSnapshot(ModelSetupStage Stage, double FractionCompleted)
{
    /// <summary>A fraction between 0 and 1; anything else an engine reports reads as 0 or 1.</summary>
    public static double Clamped(double value) => Math.Min(1, Math.Max(0, double.IsFinite(value) ? value : 0));
}

/// <summary>A model cannot be removed or replaced while a transcription or speaker identification uses it.</summary>
public sealed class ModelInUseException : InvalidOperationException
{
    public ModelInUseException()
        : base(Resources.PipelineStrings.ModelInUse)
    {
    }
}
