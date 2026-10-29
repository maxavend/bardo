using System.Text;
using System.Text.RegularExpressions;

namespace Bardo.Domain;

public static partial class TranscriptTextSanitizer
{
    [GeneratedRegex(@"<\|[^>]*\|>")]
    private static partial Regex WhisperControlToken();

    private static readonly (Regex Pattern, string Replacement)[] VocabularyReplacements =
    [
        (new Regex(@"(?i)\bfigma\b"), "Figma"),
        (new Regex(@"(?i)\bempty[- ]?state\b"), "empty state"),
        (new Regex(@"(?i)\banti[- ]?state\b"), "empty state"),
        (new Regex(@"(?i)\bsupport(?:ing| in)[- ]?text\b"), "supporting text"),
        (new Regex(@"(?i)\bdesign[- ]?system\b"), "design system"),
        (new Regex(@"(?i)\bhand[- ]?off\b"), "handoff"),
        (new Regex(@"(?i)\bbread[- ]?crumbs\b"), "breadcrumbs"),
    ];

    [GeneratedRegex(@"\.{3,}")]
    private static partial Regex Ellipsis();

    [GeneratedRegex(@"\s+([,.;:!?…])")]
    private static partial Regex SpaceBeforePunctuation();

    [GeneratedRegex(@"([¿¡])\s+")]
    private static partial Regex SpaceAfterOpeningMark();

    public static string Sanitize(string text)
    {
        var withoutControlTokens = WhisperControlToken().Replace(text, " ");
        return string.Join(' ', withoutControlTokens.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).Trim();
    }

    /// <summary>
    /// Conservative cleanup for raw ASR output. It improves presentation and fixes a
    /// small set of unambiguous product-design terms without rewriting what was said.
    /// </summary>
    public static string NormalizeRecognizedText(string text)
    {
        var value = Sanitize(text);
        foreach (var (pattern, replacement) in VocabularyReplacements)
        {
            value = pattern.Replace(value, replacement);
        }

        value = Ellipsis().Replace(value, "…");
        value = SpaceBeforePunctuation().Replace(value, "$1");
        value = SpaceAfterOpeningMark().Replace(value, "$1").Trim();

        return CapitalizeSentenceStarts(value);
    }

    private static string CapitalizeSentenceStarts(string text)
    {
        var result = new StringBuilder(text.Length);
        var shouldCapitalize = true;

        foreach (var rune in text.EnumerateRunes())
        {
            if (shouldCapitalize && Rune.IsLetter(rune))
            {
                result.Append(Rune.ToUpperInvariant(rune).ToString());
                shouldCapitalize = false;
            }
            else
            {
                result.Append(rune.ToString());
                if (Rune.IsLetterOrDigit(rune)) shouldCapitalize = false;
            }

            if (rune.Value is '.' or '!' or '?' or '…') shouldCapitalize = true;
        }

        return result.ToString();
    }
}
