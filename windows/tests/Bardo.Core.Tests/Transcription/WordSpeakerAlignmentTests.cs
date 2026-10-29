using Bardo.Diarization;
using Bardo.Domain;
using Bardo.Transcription;

namespace Bardo.Tests.Transcription;

[TestClass]
public sealed class WordSpeakerAlignmentTests
{
    [TestMethod]
    public void EachWordUsesTheSpeakerWithGreatestTemporalOverlap()
    {
        TranscriptWord[] words =
        [
            new(0, 0.4, "One"),
            new(0.5, 1.8, " two"),
            new(1.9, 2.8, " three"),
        ];
        DiarizationInterval[] intervals = [new(0, 0, 0.45), new(1, 0.45, 3)];

        var attributed = BardoWordSpeakerAligner.Align(words, intervals);

        CollectionAssert.AreEqual(new int?[] { 0, 1, 1 }, attributed.Select(word => word.SpeakerIndex).ToArray());
        CollectionAssert.AreEqual(words.Select(word => word.Text).ToArray(), attributed.Select(word => word.Word.Text).ToArray());
    }

    [TestMethod]
    public void PointTimestampUsesMidpointFallbackAndMissingEvidenceStaysNull()
    {
        TranscriptWord[] words = [new(2, 2, "point"), new(10, 11, "unknown")];
        DiarizationInterval[] intervals = [new(3, 1, 3)];

        var attributed = BardoWordSpeakerAligner.Align(words, intervals);

        CollectionAssert.AreEqual(new int?[] { 3, null }, attributed.Select(word => word.SpeakerIndex).ToArray());
    }

    [TestMethod]
    public void WordAtATurnBoundaryJoinsTheTurnItIsSpokenInto()
    {
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        // Real SpeakerKit output: "Me" was attributed to the previous voice.
        AttributedTranscriptWord[] words =
        [
            Word(18.2, 18.9, "sprint.", first),
            Word(19.8, 19.9, "Me", first),
            Word(19.9, 20.2, " parece", second),
            Word(20.2, 20.5, " bien.", second),
            Word(20.6, 20.8, " Yo", second),
            Word(20.8, 21.4, " me encargo.", second),
        ];

        var smoothed = BardoWordSpeakerAligner.SmoothingBoundaryWords(words);

        CollectionAssert.AreEqual(new Guid?[] { first, second, second, second, second, second }, Speakers(smoothed));
    }

    [TestMethod]
    public void TrailingWordJoinsThePreviousTurn()
    {
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        AttributedTranscriptWord[] words =
        [
            Word(0.2, 1.0, "Eso es todo.", first),
            Word(1.0, 1.4, " Muchas", first),
            Word(1.4, 1.7, " gracias", second),
            Word(3.0, 3.5, "Hola", second),
            Word(3.5, 3.9, " a todos", second),
        ];

        var smoothed = BardoWordSpeakerAligner.SmoothingBoundaryWords(words);

        CollectionAssert.AreEqual(new Guid?[] { first, first, first, second, second }, Speakers(smoothed));
    }

    [TestMethod]
    public void OpeningWordsOfTheConversationKeepTheirSpeaker()
    {
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        AttributedTranscriptWord[] words =
        [
            Word(0, 0.4, "Hello.", first),
            Word(0.4, 0.8, " Hi", second),
            Word(0.8, 1.1, " there.", second),
        ];

        var smoothed = BardoWordSpeakerAligner.SmoothingBoundaryWords(words);

        CollectionAssert.AreEqual(new Guid?[] { first, second, second }, Speakers(smoothed));
    }

    [TestMethod]
    public void ShortReplyWithPausesOnBothSidesKeepsItsSpeaker()
    {
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        AttributedTranscriptWord[] words =
        [
            Word(0, 0.8, "¿Listo?", first),
            Word(1.4, 1.7, "Sí.", second),
            Word(2.4, 2.9, "Bien.", first),
        ];

        var smoothed = BardoWordSpeakerAligner.SmoothingBoundaryWords(words);

        CollectionAssert.AreEqual(new Guid?[] { first, second, first }, Speakers(smoothed));
    }

    [TestMethod]
    public void QuickExchangeOfShortPhrasesKeepsBothSpeakers()
    {
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        AttributedTranscriptWord[] words =
        [
            Word(0.0, 1.0, "…el plan.", first),
            Word(1.5, 1.8, "¿Vale?", first),
            Word(1.85, 2.2, "Vale.", second),
            Word(2.8, 3.6, "Entonces…", second),
        ];

        var smoothed = BardoWordSpeakerAligner.SmoothingBoundaryWords(words);

        CollectionAssert.AreEqual(new Guid?[] { first, first, second, second }, Speakers(smoothed));
    }

    private static AttributedTranscriptWord Word(double start, double end, string text, Guid speaker) =>
        new(new TranscriptWord(start, end, text), speaker);

    private static Guid?[] Speakers(IEnumerable<AttributedTranscriptWord> words) => [.. words.Select(word => word.SpeakerId)];
}

[TestClass]
public sealed class ConversationTurnBuilderTests
{
    private readonly Guid _speakerA = Guid.NewGuid();
    private readonly Guid _speakerB = Guid.NewGuid();

    [TestMethod]
    public void SameSpeakerWithBriefPauseStaysInOneTurn()
    {
        AttributedTranscriptWord[] words =
        [
            Attributed("Entonces", 0, 0.2, _speakerA),
            Attributed(" lo", 0.25, 0.4, _speakerA),
            Attributed(" revisamos.", 0.75, 1.0, _speakerA),
        ];

        var turns = BardoConversationTurnBuilder.Build(words);

        Assert.HasCount(1, turns);
        Assert.AreEqual("Entonces lo revisamos.", turns[0].Text);
        Assert.AreEqual(0, turns[0].StartTime);
        Assert.AreEqual(1.0, turns[0].EndTime);
    }

    [TestMethod]
    public void SameSpeakerWithLongPauseStartsAnotherTurn()
    {
        AttributedTranscriptWord[] words =
        [
            Attributed("Primero.", 0, 0.3, _speakerA),
            Attributed("Después.", 1.6, 1.9, _speakerA),
        ];

        var turns = BardoConversationTurnBuilder.Build(words);

        CollectionAssert.AreEqual(new[] { "Primero.", "Después." }, turns.Select(turn => turn.Text).ToArray());
    }

    [TestMethod]
    public void SpeakerChangeAlwaysCreatesBoundaryIncludingBackchannel()
    {
        AttributedTranscriptWord[] words =
        [
            Attributed("Yo creo que", 0, 0.5, _speakerA),
            Attributed(" perdón", 0.55, 0.75, _speakerB),
            Attributed(" sí, dime.", 0.8, 1.2, _speakerA),
        ];

        var turns = BardoConversationTurnBuilder.Build(words);

        CollectionAssert.AreEqual(new Guid?[] { _speakerA, _speakerB, _speakerA }, turns.Select(turn => turn.SpeakerId).ToArray());
        CollectionAssert.AreEqual(new[] { "Yo creo que", "perdón", "sí, dime." }, turns.Select(turn => turn.Text).ToArray());
    }

    [TestMethod]
    public void LongMonologueSplitsAtNaturalSentenceBoundary()
    {
        AttributedTranscriptWord[] words =
        [
            Attributed("Esta es una explicación bastante larga.", 0, 31, _speakerA),
            Attributed("Y esta es la siguiente idea.", 31.7, 33, _speakerA),
        ];

        var turns = BardoConversationTurnBuilder.Build(words);

        Assert.HasCount(2, turns);
        Assert.AreEqual("Esta es una explicación bastante larga.", turns[0].Text);
    }

    [TestMethod]
    public void BlankAndUntimedWordsAreLeftOut()
    {
        AttributedTranscriptWord[] words =
        [
            Attributed("  ", 0, 0.2, _speakerA),
            Attributed("Hola", double.NaN, 0.4, _speakerA),
            Attributed("Chao", 0.6, 0.5, _speakerA),
        ];

        Assert.IsEmpty(BardoConversationTurnBuilder.Build(words));
    }

    private static AttributedTranscriptWord Attributed(string text, double start, double end, Guid? speaker) =>
        new(new TranscriptWord(start, end, text), speaker);
}
