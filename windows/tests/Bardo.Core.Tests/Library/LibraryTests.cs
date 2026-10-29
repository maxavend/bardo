using System.Globalization;
using Bardo.Domain;
using Bardo.Library;
using Bardo.Resources;
using static Bardo.Tests.Fixtures;

namespace Bardo.Tests.Library;

[TestClass]
public sealed class LibraryTests
{
    private static readonly CultureInfo Spanish = CultureInfo.GetCultureInfo("es-CL");

    [TestMethod]
    public void SectionsSplitRecordedFromImported()
    {
        var meeting = new Recording("Reunión", [AudioSource.Microphone, AudioSource.SystemAudio]);
        var imported = new Recording("Entrevista", [AudioSource.ImportedFile]);

        Assert.IsTrue(LibrarySection.All.Contains(meeting) && LibrarySection.All.Contains(imported));
        Assert.IsTrue(LibrarySection.Recorded.Contains(meeting));
        Assert.IsFalse(LibrarySection.Recorded.Contains(imported));
        Assert.IsTrue(LibrarySection.Imported.Contains(imported));
        Assert.IsFalse(LibrarySection.Imported.Contains(meeting));
    }

    [TestMethod]
    public void ListDatesGetShorterTheNearerTheyAre()
    {
        var now = new DateTimeOffset(2026, 10, 28, 15, 0, 0, TimeZoneInfo.Local.GetUtcOffset(new DateTime(2026, 10, 28, 15, 0, 0)));

        Assert.AreEqual(now.AddHours(-3).ToString(Spanish.DateTimeFormat.ShortTimePattern, Spanish), LibraryFormatting.ListDate(now.AddHours(-3), now, Spanish));
        Assert.AreEqual(Strings.Yesterday, LibraryFormatting.ListDate(now.AddDays(-1), now, Spanish));
        Assert.AreEqual("Viernes", LibraryFormatting.ListDate(now.AddDays(-5), now, Spanish), "The weekday within the past week");
        Assert.AreEqual(now.AddDays(-40).ToString("d MMM", Spanish), LibraryFormatting.ListDate(now.AddDays(-40), now, Spanish));
        StringAssert.EndsWith(LibraryFormatting.ListDate(now.AddYears(-1), now, Spanish), "2025");
    }

    [TestMethod]
    public void TechnicalTitlesGiveWayToTheDate()
    {
        var id = Guid.NewGuid();
        var technical = new Recording($"Recording {id.ToString()[..8].ToUpperInvariant()}", [AudioSource.Microphone], id: id);
        var named = new Recording("  Revisión  ", [AudioSource.Microphone]);

        StringAssert.StartsWith(LibraryFormatting.RecordingTitle(technical), Strings.RecordingFrom("").TrimEnd());
        Assert.AreEqual("Revisión", LibraryFormatting.RecordingTitle(named));
    }

    [TestMethod]
    public void SourcesReadInTheMacOrder()
    {
        Assert.AreEqual($"{Strings.SourceMicrophone} + {Strings.SourceSystemAudio}",
            LibraryFormatting.Sources([AudioSource.SystemAudio, AudioSource.Microphone]));
        Assert.AreEqual(Strings.UnknownSource, LibraryFormatting.Sources([]));
    }

    [TestMethod]
    public void SearchFindsAnyWordIgnoringCaseAndAccents()
    {
        var valentina = new Speaker(name: "Valentína");
        var recording = new Recording("Revisión de diseño", [AudioSource.Microphone]);
        var transcript = new Transcript(recording.Id, Metadata(), speakers: [valentina],
            segments: [new TranscriptSegment(0, 2, "Hablemos del onboarding.", speakerId: valentina.Id)]);

        Assert.IsTrue(LibrarySearch.Matches(recording, null, "REVISION"), "Title, without the accent");
        Assert.IsTrue(LibrarySearch.Matches(recording, transcript, "valentina"), "A participant");
        Assert.IsTrue(LibrarySearch.Matches(recording, transcript, "nada onboarding"), "Any of the words");
        Assert.IsFalse(LibrarySearch.Matches(recording, transcript, "presupuesto"));
        Assert.IsFalse(LibrarySearch.Matches(recording, null, "onboarding"), "What was said needs a transcript");
        Assert.IsTrue(LibrarySearch.Matches(recording, null, "   "), "An empty search shows everything");
    }
}
