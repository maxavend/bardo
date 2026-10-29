using Bardo.Diarization;

namespace Bardo.Engines.Tests;

[TestClass]
public sealed class SpeakerTurnTests
{
    [TestMethod]
    public void ShortSilencesBetweenVoicesAreSplitAtTheirMiddle()
    {
        var turns = SherpaSpeakerIdentifier.ClosingGaps(
        [
            new SpeakerTurn(1, 5.46, 9.21),
            new SpeakerTurn(0, 0.03, 4.71),
            new SpeakerTurn(0, 10.19, 14.66),
            new SpeakerTurn(1, 20, 25),
        ]);

        Assert.AreEqual(0.03, turns[0].StartTime, "Sorted, and the first turn keeps its start");
        Assert.AreEqual(5.085, turns[0].EndTime, 1e-9);
        Assert.AreEqual(5.085, turns[1].StartTime, 1e-9);
        Assert.AreEqual(9.7, turns[1].EndTime, 1e-9);
        Assert.AreEqual(14.66, turns[2].EndTime, "A long silence stays silence");
        Assert.AreEqual(20, turns[3].StartTime);
    }
}
