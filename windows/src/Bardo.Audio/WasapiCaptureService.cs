using Bardo.Capture;
using Bardo.Domain;
using Bardo.Persistence;

namespace Bardo.Audio;

/// <summary>Captures with WASAPI and publishes to the Library: the recorder's Windows side.</summary>
public sealed class WasapiCaptureService(RecordingStore store, CaptureStaging staging) : ICaptureService
{
    private readonly CapturePublisher _publisher = new(store, staging);

    public ICaptureSession Start(CaptureMode mode, string? microphoneDeviceId) =>
        new Session(CaptureRecorder.Start(staging, "", new CaptureSources(
            Microphone: mode != CaptureMode.SystemAudio,
            SystemAudio: mode != CaptureMode.Microphone,
            microphoneDeviceId)));

    public Task<Recording?> PublishAsync(CaptureManifest manifest, AudioEncoding encoding, CancellationToken cancellationToken) =>
        _publisher.PublishAsync(manifest, encoding, cancellationToken);

    public IReadOnlyList<CaptureManifest> Interrupted() => staging.Interrupted();

    public void Discard(CaptureManifest manifest) => staging.Discard(manifest.RecordingId);

    private sealed class Session(CaptureRecorder recorder) : ICaptureSession
    {
        public CaptureManifest Manifest => recorder.Manifest;
        public double Elapsed => recorder.Elapsed;
        public bool IsPaused => recorder.IsPaused;

        public bool IsMicrophoneMuted
        {
            get => recorder.IsMicrophoneMuted;
            set => recorder.IsMicrophoneMuted = value;
        }

        public float MicrophoneLevel => recorder.MicrophoneLevel;
        public float SystemLevel => recorder.SystemLevel;

        public void Pause() => recorder.Pause();

        public void Unpause() => recorder.Resume();

        public RecordingMoment AddMoment(string title, string? note) => recorder.AddMoment(title, note);

        public RecordingSection AddSection(string title) => recorder.AddSection(title);

        public Task<CaptureManifest> StopAsync() => recorder.StopAsync();

        public void Dispose() => recorder.Dispose();
    }
}
