using Bardo.Domain;
using Bardo.Library;
using static Bardo.Tests.Fixtures;

namespace Bardo.Tests.Library;

[TestClass]
public sealed class SpeakerPlaybackFilterTests
{
    private readonly Speaker _valentina = new(name: "Valentina");
    private readonly Speaker _diego = new(name: "Diego");
    private readonly Speaker _you = new(role: SpeakerRole.LocalUser);

    private Transcript TranscriptOf(params (double Start, double End, Speaker? Speaker)[] turns) => new(
        Guid.NewGuid(),
        Metadata(),
        speakers: [_valentina, _diego, _you],
        segments: [.. turns.Select(turn => new TranscriptSegment(turn.Start, turn.End, "…", turn.Speaker?.Id))]);

    [TestMethod]
    public void OnlyTheChosenParticipantsTurnsPlay()
    {
        var transcript = TranscriptOf((2, 10, _valentina), (10, 20, _diego), (20, 30, _valentina), (30, 40, _you));

        var skipped = SpeakerPlaybackFilter.SkippedRanges(transcript, new HashSet<Guid> { _valentina.Id }, 45);

        CollectionAssert.AreEqual(new TimeRange[] { new(0, 1.75), new(10.25, 19.75), new(30.25, 45) }, skipped.ToArray());
    }

    [TestMethod]
    public void TwoParticipantsCanBeHeardTogether()
    {
        var transcript = TranscriptOf((0, 10, _valentina), (10, 20, _diego), (20, 30, _you));

        var skipped = SpeakerPlaybackFilter.SkippedRanges(transcript, new HashSet<Guid> { _valentina.Id, _diego.Id }, 30);

        CollectionAssert.AreEqual(new TimeRange[] { new(20.25, 30) }, skipped.ToArray());
    }

    [TestMethod]
    public void ShortGapsBetweenKeptTurnsPlayThrough()
    {
        // Diego's quick "sí" between two of Valentina's turns is not worth a jump.
        var transcript = TranscriptOf((0, 10, _valentina), (10.2, 10.9, _diego), (11, 20, _valentina));

        var skipped = SpeakerPlaybackFilter.SkippedRanges(transcript, new HashSet<Guid> { _valentina.Id }, 20);

        Assert.IsEmpty(skipped);
    }

    [TestMethod]
    public void TextNobodySaidIsSkipped()
    {
        var transcript = TranscriptOf((0, 5, _valentina), (5, 15, null), (15, 20, _valentina));

        var skipped = SpeakerPlaybackFilter.SkippedRanges(transcript, new HashSet<Guid> { _valentina.Id }, 20);

        CollectionAssert.AreEqual(new TimeRange[] { new(5.25, 14.75) }, skipped.ToArray());
    }

    [TestMethod]
    public void OverlappingSkipsJoinIntoOne()
    {
        var merged = SpeakerPlaybackFilter.Merged([new(10, 20), new(0, 2), new(18, 25), new(25, 30), new(40, 41)]);

        CollectionAssert.AreEqual(new TimeRange[] { new(0, 2), new(10, 30), new(40, 41) }, merged.ToArray());
    }
}
