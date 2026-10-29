using Bardo.Domain;

namespace Bardo.Tests.Domain;

[TestClass]
public sealed class TranscriptTextSanitizerTests
{
    [TestMethod]
    public void RemovesWhisperControlAndTimestampTokens() =>
        Assert.AreEqual("Hola, bueno", TranscriptTextSanitizer.Sanitize("<|startoftranscript|><|transcribe|><|0.00|> Hola, bueno <|6.58|>"));

    [TestMethod]
    public void CollapsesWhitespaceAfterRemovingTokens() =>
        Assert.AreEqual("Hola y ver si esto funciona.", TranscriptTextSanitizer.Sanitize("  Hola   <|6.58|>   y ver si esto funciona.  "));

    [TestMethod]
    public void NormalizesProductVocabularyAndPunctuationWithoutParaphrasing() =>
        Assert.AreEqual(
            "Figma tiene un empty state… Y un supporting text, después handoff.",
            TranscriptTextSanitizer.NormalizeRecognizedText("  figma tiene un anti-state ... y un support in text , después hand-off.  "));

    [TestMethod]
    public void CapitalizesSentenceStartsButPreservesExistingWords() =>
        Assert.AreEqual("Hola equipo. Revisemos UX y UI.", TranscriptTextSanitizer.NormalizeRecognizedText("hola equipo. revisemos UX y UI."));

    [TestMethod]
    public void DisplayTextSanitizesLegacyStoredSegments() =>
        Assert.AreEqual("Texto visible", new TranscriptSegment(0, 4, "<|0.00|> Texto visible <|4.00|>").DisplayText);
}
