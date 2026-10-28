using System.Buffers.Binary;
using Bardo.Capture;
using Bardo.Domain;

namespace Bardo.Tests.Capture;

[TestClass]
public sealed class CaptureTests
{
    private TemporaryDirectory _root = null!;

    [TestInitialize]
    public void SetUp() => _root = new TemporaryDirectory("BardoCapture");

    [TestCleanup]
    public void TearDown() => _root.Dispose();

    /// <summary>A 16-bit WAV whose header still says what it said when recording began.</summary>
    private string CrashedWave(int sampleRate, int channels, int frames, int declaredFrames, bool tornFrame = false)
    {
        var path = Path.Combine(_root.Path, $"{Guid.NewGuid()}.wav");
        var blockAlign = channels * 2;
        using var stream = File.Create(path);
        using var writer = new BinaryWriter(stream);
        writer.Write("RIFF"u8);
        writer.Write(36 + declaredFrames * blockAlign);
        writer.Write("WAVE"u8);
        writer.Write("fmt "u8);
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)channels);
        writer.Write(sampleRate);
        writer.Write(sampleRate * blockAlign);
        writer.Write((short)blockAlign);
        writer.Write((short)16);
        writer.Write("data"u8);
        writer.Write(declaredFrames * blockAlign);
        for (var i = 0; i < frames * channels; i++) writer.Write((short)(i % 2 == 0 ? 16384 : -16384));
        if (tornFrame) writer.Write((byte)1);
        return path;
    }

    [TestMethod]
    public void RepairKeepsEverythingRecordedBeforeACrash()
    {
        var path = CrashedWave(48_000, 2, frames: 48_000 * 3, declaredFrames: 48_000, tornFrame: true);

        Assert.IsTrue(WaveFile.Repair(path));

        Assert.AreEqual(3, WaveFile.Duration(path), 1e-9);
        var bytes = File.ReadAllBytes(path);
        Assert.AreEqual(48_000 * 3 * 4, BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(40)), "data size");
        Assert.AreEqual(bytes.Length - 8, BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(4)), "RIFF size");
        Assert.IsFalse(WaveFile.Repair(path), "A sound file is left alone");
    }

    [TestMethod]
    public void SamplesAreMixedDownToMono()
    {
        var path = CrashedWave(16_000, 2, frames: 4, declaredFrames: 4);

        var samples = WaveFile.ReadMonoSamples(path, out var rate);

        Assert.AreEqual(16_000, rate);
        Assert.HasCount(4, samples);
        Assert.AreEqual(0, samples[0], 1e-6, "Left and right cancel out");
    }

    [TestMethod]
    public void SilentSystemAudioIsFilledSoTracksStayAligned()
    {
        var clock = new TrackClock(48_000);
        clock.Advance(48_000);

        Assert.AreEqual(0, clock.SilenceBefore(4_800, elapsedSeconds: 1.1), "On time");
        Assert.AreEqual(0, clock.SilenceBefore(4_800, elapsedSeconds: 1.12), "Jitter is not silence");
        Assert.AreEqual(96_000, clock.SilenceBefore(4_800, elapsedSeconds: 3.1), "Two silent seconds");
        Assert.AreEqual(48_000 * 4, clock.SilenceToEnd(5));
    }

    [TestMethod]
    public void PausedTimeDoesNotCount()
    {
        var now = TimeSpan.Zero;
        var clock = new CaptureClock(() => now);

        now = TimeSpan.FromSeconds(10);
        clock.Pause();
        now = TimeSpan.FromSeconds(25);
        Assert.AreEqual(10, clock.Elapsed);
        clock.Resume();
        now = TimeSpan.FromSeconds(30);

        Assert.AreEqual(15, clock.Elapsed);
        Assert.IsFalse(clock.IsPaused);
    }

    [TestMethod]
    public void InterruptedCapturesAreFoundWithTheirNotes()
    {
        var staging = new CaptureStaging(_root.Path);
        var manifest = staging.Begin("Reunión", [CaptureTrackKind.Microphone, CaptureTrackKind.SystemAudio], DateTimeOffset.UtcNow);
        staging.Save(manifest with { Notes = RecordingNotes.Empty.AddingMoment(12, "Idea", null).Notes });
        File.WriteAllText(staging.TrackPath(manifest, manifest.Tracks[0]), "audio");
        var empty = staging.Begin("Nada", [CaptureTrackKind.Microphone], DateTimeOffset.UtcNow);

        var interrupted = staging.Interrupted();

        Assert.HasCount(1, interrupted, "A capture without audio has nothing to recover");
        Assert.AreEqual("Reunión", interrupted[0].Title);
        Assert.AreEqual("Idea", interrupted[0].Notes.Moments[0].Title);
        CollectionAssert.AreEquivalent(new[] { AudioSource.Microphone, AudioSource.SystemAudio }, interrupted[0].Sources.ToArray());

        staging.Discard(empty.RecordingId);
        Assert.IsFalse(Directory.Exists(staging.DirectoryFor(empty.RecordingId)));
    }
}
