using Bardo.Domain;
using Bardo.Resources;
using Bardo.Serialization;
using static Bardo.Tests.Fixtures;

namespace Bardo.Tests.Domain;

[TestClass]
public sealed class SpeakerNamingTests
{
    [TestMethod]
    public void MergingGivesEverythingToOnePersonAndKeepsYouAsYou()
    {
        var you = new Speaker(role: SpeakerRole.LocalUser);
        var eloin = new Speaker(name: "Eloín");
        var alsoEloin = new Speaker();
        var transcript = new Transcript(Guid.NewGuid(), Metadata(),
            speakers: [you, eloin, alsoEloin],
            segments:
            [
                new TranscriptSegment(0, 1, "Hola", speakerId: eloin.Id),
                new TranscriptSegment(1, 2, "Sí", speakerId: alsoEloin.Id),
                new TranscriptSegment(2, 3, "Yo", speakerId: you.Id),
            ]);

        var merged = transcript.MergingSpeaker(eloin.Id, alsoEloin.Id);
        CollectionAssert.AreEqual(new[] { you.Id, alsoEloin.Id }, merged.Speakers.Select(speaker => speaker.Id).ToArray());
        Assert.AreEqual("Eloín", merged.Speakers[1].Name, "The typed name is kept when the other has none");
        CollectionAssert.AreEqual(new Guid?[] { alsoEloin.Id, alsoEloin.Id, you.Id }, merged.Segments.Select(segment => segment.SpeakerId).ToArray());

        var intoOther = transcript.MergingSpeaker(you.Id, eloin.Id);
        CollectionAssert.AreEqual(new[] { you.Id, alsoEloin.Id }, intoOther.Speakers.Select(speaker => speaker.Id).ToArray(), "You on the microphone always stay you");
        Assert.AreEqual(you.Id, intoOther.Segments[0].SpeakerId);
    }

    [TestMethod]
    public void ParticipantsGivenTheSameNameAreOfferedAsOne()
    {
        var first = new Speaker(name: "Eloín");
        var second = new Speaker();
        var third = new Speaker(name: "Dani");
        var transcript = new Transcript(Guid.NewGuid(), Metadata(), speakers: [first, second, third]);

        var groups = transcript.SpeakersSharingAName(new Dictionary<Guid, string> { [second.Id] = " eloin " });

        Assert.HasCount(1, groups);
        CollectionAssert.AreEqual(new[] { first.Id, second.Id }, groups[0].ToArray());
        Assert.IsEmpty(transcript.SpeakersSharingAName(new Dictionary<Guid, string>()));
    }

    [TestMethod]
    public void UnnamedSpeakersAreYouOthersOrANumber()
    {
        var you = new Speaker(role: SpeakerRole.LocalUser);
        var others = new Speaker(role: SpeakerRole.Others);
        var first = new Speaker();
        var second = new Speaker();
        var transcript = new Transcript(Guid.NewGuid(), Metadata(), speakers: [you, others, first, second]);

        Assert.AreEqual(Strings.LocalSpeaker, transcript.DisplayName(you, localName: null));
        Assert.AreEqual("Max", transcript.DisplayName(you, localName: "Max"));
        Assert.AreEqual(Strings.OtherSpeakers, transcript.DisplayName(others, localName: null));
        Assert.AreEqual(Strings.NumberedSpeaker(2), transcript.DisplayName(second, localName: null));
        Assert.AreEqual("Ana", transcript.DisplayName(second with { Name = " Ana " }, localName: null));
    }
}

[TestClass]
public sealed class TranscriptParagraphingTests
{
    private static TranscriptSegment Segment(string text, double start, double length = 2, Guid? speaker = null) =>
        new(start, start + length, text, speakerId: speaker);

    private static int Words(IReadOnlyList<TranscriptSegment> group) =>
        group.Sum(segment => TranscriptParagraphing.WordCount(segment.DisplayText));

    [TestMethod]
    public void ShortBreathsDoNotLeaveLinesOfFiveWords()
    {
        // Five-word phrases with a three-second breath between each.
        var segments = Enumerable.Range(0, 8).Select(index => Segment("Una frase corta de cinco.", index * 5));
        var paragraphs = TranscriptParagraphing.Paragraphs(segments);

        Assert.IsLessThan(4, paragraphs.Count, "Breaths are joined until a paragraph has its minimum");
        Assert.IsTrue(paragraphs.SkipLast(1).All(group => Words(group) >= TranscriptParagraphing.MinimumWords));
    }

    [TestMethod]
    public void AMonologueBecomesParagraphsAtSentenceEnds()
    {
        // Forty ten-word sentences with no pause at all.
        var segments = Enumerable.Range(0, 40).Select(index => Segment("Esta es una oración de diez palabras para leer bien.", index * 2));
        var paragraphs = TranscriptParagraphing.Paragraphs(segments);

        Assert.IsGreaterThan(4, paragraphs.Count, "No wall of text");
        foreach (var group in paragraphs) Assert.IsLessThanOrEqualTo(TranscriptParagraphing.ComfortableWords + 10, Words(group));
    }

    [TestMethod]
    public void EveryTurnAndLongSilenceStartsAParagraph()
    {
        Guid you = Guid.NewGuid(), them = Guid.NewGuid();
        var segments = new[]
        {
            Segment("Hola.", 0, speaker: you),
            Segment("Ya, ok.", 2.2, speaker: them),
            Segment("Después de un rato.", 12, speaker: them),
        };

        CollectionAssert.AreEqual(new[] { 1, 1, 1 }, TranscriptParagraphing.Paragraphs(segments).Select(group => group.Count).ToArray());
    }
}

[TestClass]
public sealed class TranscriptTextFormatterTests
{
    private readonly Speaker _you = new(role: SpeakerRole.LocalUser);
    private readonly Speaker _valentina = new(name: "Valentina");

    private static TranscriptSegment Segment(double start, double end, Speaker? speaker, string text) =>
        new(start, end, text, speakerId: speaker?.Id);

    private static Transcript Transcript(EquatableArray<TranscriptSegment> segments, EquatableArray<Speaker> speakers) =>
        new(Guid.NewGuid(), Metadata(), speakers: speakers, segments: segments);

    [TestMethod]
    public void OnePersonSpeakingWithoutLongPausesIsOneBlock()
    {
        var formatter = new TranscriptTextFormatter("Revisión");
        var transcript = Transcript(
        [
            Segment(0, 50, _valentina, "Partamos por el onboarding."),
            Segment(52, 130, _valentina, "Bajamos de siete datos a tres."),
            Segment(133, 240, _valentina, "Y medimos la primera visita."),
            Segment(241, 252, _you, "Exacto."),
            Segment(270, 280, _you, "Lo vemos el jueves."),
        ], [_you, _valentina]);

        var blocks = formatter.Blocks(transcript);

        CollectionAssert.AreEqual(new[] { "Valentina", Strings.LocalSpeaker, Strings.LocalSpeaker }, blocks.Select(block => block.Speaker).ToArray());
        Assert.AreEqual(0, blocks[0].Start);
        Assert.AreEqual(240, blocks[0].End, "Four minutes of one voice stay together");
        Assert.AreEqual("Partamos por el onboarding. Bajamos de siete datos a tres. Y medimos la primera visita.", blocks[0].Text);
        Assert.AreEqual(252, blocks[1].End);
        Assert.AreEqual(270, blocks[2].Start, "A long pause starts a new block");
    }

    [TestMethod]
    public void TextHasTitleDateAndTimedBlocks()
    {
        var formatter = new TranscriptTextFormatter("Revisión", BardoTime.FromSecondsSince1970(1_792_000_000), 280, localName: "Max");
        var lines = formatter.Text(Transcript(
        [
            Segment(0, 72, _valentina, "Partamos."),
            Segment(72, 152, _you, "Exacto."),
        ], [_you, _valentina])).Split('\n');

        Assert.AreEqual("Revisión", lines[0]);
        Assert.IsTrue(lines[1].EndsWith("· 4:40", StringComparison.Ordinal), lines[1]);
        CollectionAssert.AreEqual(new[] { "", "Valentina (0:00–1:12)", "Partamos.", "", "Max (1:12–2:32)", "Exacto." }, lines[2..]);
    }

    [TestMethod]
    public void WithoutSpeakersLongStretchesAreStillSplit()
    {
        var formatter = new TranscriptTextFormatter("Nota");
        var segments = Enumerable.Range(0, 10).Select(index => Segment(index * 30, index * 30 + 29, null, "Idea.")).ToEquatableArray();

        var blocks = formatter.Blocks(Transcript(segments, []));

        Assert.IsGreaterThan(1, blocks.Count);
        Assert.IsTrue(blocks.All(block => block.Speaker is null && block.End - block.Start <= 150));
    }

    [TestMethod]
    public void DurationsReadLikeAClock()
    {
        Assert.AreEqual("0:00", DurationFormatting.Duration(-3));
        Assert.AreEqual("12:31", DurationFormatting.Duration(751));
        Assert.AreEqual("1:02:05", DurationFormatting.Duration(3_725));
    }
}
