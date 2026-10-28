using Bardo.Capture;
using Bardo.Domain;

namespace Bardo.Tests.Capture;

[TestClass]
public sealed class RecorderViewModelTests
{
    [TestMethod]
    public async Task AMeetingRecordsMarksAndPublishes()
    {
        var service = new FakeCaptureService();
        var recorder = new RecorderViewModel(service);

        recorder.Start(CaptureMode.Meeting, microphoneDeviceId: null);
        Assert.IsTrue(recorder.IsRecording);
        Assert.IsTrue(recorder.HasMicrophone && recorder.HasSystemAudio);

        service.Session.Elapsed = 65.4;
        recorder.Tick();
        Assert.AreEqual("1:05", recorder.ElapsedText);
        Assert.AreEqual(0.5, recorder.MicrophoneLevel, 1e-6);

        recorder.AddSection();
        recorder.AddMoment("Decisión");
        CollectionAssert.AreEqual(new[] { Bardo.Resources.Strings.SectionTitle(1), "Decisión" }, recorder.Marks.Select(mark => mark.Title).ToArray());

        recorder.IsMicrophoneMuted = true;
        recorder.Tick();
        Assert.AreEqual(0, recorder.MicrophoneLevel, "A muted microphone shows no level");

        recorder.TogglePause();
        Assert.IsTrue(recorder.IsPaused);

        var recording = await recorder.StopAsync(AudioEncoding.Default);

        Assert.IsNotNull(recording);
        Assert.IsFalse(recorder.IsRecording);
        Assert.AreEqual("0:00", recorder.ElapsedText);
        Assert.HasCount(1, service.Published[0].Notes.Moments);
    }

    private sealed class FakeCaptureService : ICaptureService
    {
        public FakeSession Session { get; private set; } = null!;
        public List<CaptureManifest> Published { get; } = [];

        public ICaptureSession Start(CaptureMode mode, string? microphoneDeviceId)
        {
            var tracks = mode == CaptureMode.Meeting
                ? new[] { CaptureTrackKind.Microphone, CaptureTrackKind.SystemAudio }
                : [mode == CaptureMode.Microphone ? CaptureTrackKind.Microphone : CaptureTrackKind.SystemAudio];
            Session = new FakeSession(new CaptureManifest(Guid.NewGuid(), "", DateTimeOffset.UtcNow,
                [.. tracks.Select(kind => new CaptureTrack(Guid.NewGuid(), kind, "a.wav"))], RecordingNotes.Empty));
            return Session;
        }

        public Task<Recording?> PublishAsync(CaptureManifest manifest, AudioEncoding encoding, CancellationToken cancellationToken)
        {
            Published.Add(manifest);
            return Task.FromResult<Recording?>(new Recording(manifest.Title, manifest.Sources, id: manifest.RecordingId));
        }

        public IReadOnlyList<CaptureManifest> Interrupted() => [];

        public void Discard(CaptureManifest manifest)
        {
        }
    }

    private sealed class FakeSession(CaptureManifest manifest) : ICaptureSession
    {
        public CaptureManifest Manifest { get; private set; } = manifest;
        public double Elapsed { get; set; }
        public bool IsPaused { get; private set; }
        public bool IsMicrophoneMuted { get; set; }
        public float MicrophoneLevel => 0.5f;
        public float SystemLevel => 0.25f;

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
    }
}
