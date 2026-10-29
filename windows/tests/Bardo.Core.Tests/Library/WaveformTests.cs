using Bardo.Capture;
using Bardo.Domain;
using Bardo.Library;
using static Bardo.Tests.Fixtures;

namespace Bardo.Tests.Library;

[TestClass]
public sealed class WaveformTests
{
    [TestMethod]
    public void LoudnessIsOnADecibelScale()
    {
        Assert.AreEqual(0, Waveform.Level(0));
        Assert.AreEqual(0, Waveform.Level(0.001), 1e-6, "-60 dB is silence");
        Assert.AreEqual(1, Waveform.Level(1), 1e-6);
        Assert.AreEqual(0.6, Waveform.Level(0.1), 1e-6, "-20 dB sits above the middle, so speech reads clearly");
    }

    [TestMethod]
    public void PoolingKeepsAShortLoudBin()
    {
        float[] levels = [0, 0, 0, 0, 0, 0.9f, 0, 0];

        CollectionAssert.AreEqual(new[] { 0f, 0.9f }, Waveform.Bars(levels, 2));
        Assert.HasCount(16, Waveform.Bars(levels, 16), "Stretched when there is room for more bars");
        Assert.IsEmpty(Waveform.Bars([], 10));
    }

    [TestMethod]
    public async Task AnOverviewFollowsTheSound()
    {
        using var root = new TemporaryDirectory("BardoWaveform");
        var path = Path.Combine(root.Path, "tone.wav");
        WriteTone(path, seconds: 2, loudFrom: 1);

        var levels = await Waveform.OverviewAsync(new WaveDecoder(), path, 2, CancellationToken.None, bins: 4);

        Assert.HasCount(4, levels);
        Assert.AreEqual(0, levels[0], "The first second is silent");
        Assert.IsGreaterThan(0.8f, levels[3]);
    }

    [TestMethod]
    public void BarsTakeTheirSpeakersColour()
    {
        var ana = new Speaker(name: "Ana");
        var luis = new Speaker(name: "Luis");
        var transcript = new Transcript(Guid.NewGuid(), Metadata(), speakers: [ana, luis], segments:
        [
            new TranscriptSegment(0, 4, "Hola", speakerId: ana.Id),
            new TranscriptSegment(6, 10, "Qué tal", speakerId: luis.Id),
        ]);

        CollectionAssert.AreEqual(new[] { 0, 0, -1, 1, 1 }, Waveform.Speakers(transcript, 10, 5));
        CollectionAssert.AreEqual(new[] { -1, -1 }, Waveform.Speakers(null, 10, 2));
    }

    private static void WriteTone(string path, int seconds, int loudFrom)
    {
        const int rate = 16_000;
        using var writer = new BinaryWriter(File.Create(path));
        var frames = rate * seconds;
        writer.Write("RIFF"u8);
        writer.Write(36 + frames * 2);
        writer.Write("WAVEfmt "u8);
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)1);
        writer.Write(rate);
        writer.Write(rate * 2);
        writer.Write((short)2);
        writer.Write((short)16);
        writer.Write("data"u8);
        writer.Write(frames * 2);
        for (var frame = 0; frame < frames; frame++)
        {
            var loud = frame >= loudFrom * rate;
            writer.Write((short)(loud ? 30_000 * Math.Sin(frame * 2 * Math.PI * 440 / rate) : 0));
        }
    }
}
