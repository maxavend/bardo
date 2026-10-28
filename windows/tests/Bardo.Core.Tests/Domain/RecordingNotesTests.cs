using Bardo.Domain;
using Bardo.Resources;
using static Bardo.Tests.Fixtures;

namespace Bardo.Tests.Domain;

[TestClass]
public sealed class RecordingNotesTests
{
    [TestMethod]
    public void MomentsAndSectionsStayInTimeOrderWithReadableDefaults()
    {
        var notes = RecordingNotes.Empty;
        notes = notes.AddingMoment(90, "  ", "  ").Notes;
        notes = notes.AddingMoment(30, "Decisión", "Lanzar el jueves").Notes;
        notes = notes.AddingSection(60, "").Notes;
        notes = notes.AddingSection(0, "Contexto").Notes;

        CollectionAssert.AreEqual(new[] { 30.0, 90.0 }, notes.Moments.Select(moment => moment.Time).ToArray());
        Assert.AreEqual(RecordingMoment.DefaultTitle(90), notes.Moments[1].Title, "A blank moment is titled after its time");
        Assert.IsNull(notes.Moments[1].Note);
        CollectionAssert.AreEqual(new[] { "Contexto", Strings.SectionTitle(1) }, notes.Sections.Select(section => section.Title).ToArray());
        Assert.AreEqual(60, notes.End(notes.Sections[0], 120), "A section ends where the next starts");
        Assert.AreEqual(120, notes.End(notes.Sections[1], 120));
    }

    [TestMethod]
    public void EditingKeepsTheTimeAndBlankTitlesFallBack()
    {
        var (notes, moment) = RecordingNotes.Empty.AddingMoment(12, "Primero", null);
        notes = notes.EditingMoment(moment.Id, "", "Detalle");

        Assert.AreEqual(12, notes.Moments[0].Time);
        Assert.AreEqual(RecordingMoment.DefaultTitle(12), notes.Moments[0].Title);
        Assert.AreEqual("Detalle", notes.Moments[0].Note);

        Assert.IsTrue(notes.RemovingMoment(moment.Id).IsEmpty);
    }

    [TestMethod]
    public void NotesSitAmongParagraphsWhereTheyHappened()
    {
        var notes = RecordingNotes.Empty
            .AddingSection(39.5, "Propuesta").Notes
            .AddingSection(500, "Cierre").Notes
            .AddingMoment(2, "Antes de hablar", null).Notes
            .AddingMoment(24, "Durante", null).Notes;

        var placement = new TranscriptNotePlacement(notes, [5, 18, 40, 58]);

        CollectionAssert.AreEqual(new[] { "Antes de hablar" }, placement.LeadingMoments.Select(moment => moment.Title).ToArray(), "A moment before anyone speaks comes first");
        CollectionAssert.AreEqual(new[] { "Propuesta" }, placement.SectionsBefore(2).Select(section => section.Title).ToArray(), "A section heads the paragraph it starts");
        CollectionAssert.AreEqual(new[] { "Durante" }, placement.MomentsAfter(1).Select(moment => moment.Title).ToArray(), "A moment follows the paragraph it was marked in");
        CollectionAssert.AreEqual(new[] { "Cierre" }, placement.TrailingSections.Select(section => section.Title).ToArray());
    }

    [TestMethod]
    public void CopiedTextIncludesSectionsAndMoments()
    {
        var notes = RecordingNotes.Empty
            .AddingSection(0, "Planificación").Notes
            .AddingMoment(20, "Fecha", "Definir con Diego").Notes;
        var valentina = new Speaker(name: "Valentina");
        var transcript = new Transcript(Guid.NewGuid(), Metadata(), speakers: [valentina],
            segments: [new TranscriptSegment(0, 72, "Partamos.", speakerId: valentina.Id)]);

        var text = new TranscriptTextFormatter("Revisión", notes: notes).Text(transcript);

        CollectionAssert.AreEqual(new[]
        {
            "Revisión",
            "",
            "PLANIFICACIÓN · 0:00",
            "",
            "Valentina (0:00–1:12)",
            "Partamos.",
            "⚑ 0:20 · Fecha: Definir con Diego",
        }, text.Split('\n'));
    }

    [TestMethod]
    public void RenamingASectionIgnoresBlankTitles()
    {
        var (notes, section) = RecordingNotes.Empty.AddingSection(10, "Inicio");

        Assert.AreEqual("Inicio", notes.RenamingSection(section.Id, "   ").Sections[0].Title);
        Assert.AreEqual("Cierre", notes.RenamingSection(section.Id, " Cierre ").Sections[0].Title);
    }
}
