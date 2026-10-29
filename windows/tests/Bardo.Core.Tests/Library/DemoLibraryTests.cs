using Bardo.Capture;
using Bardo.Library;
using Bardo.Settings;

namespace Bardo.Tests.Library;

[TestClass]
public sealed class DemoLibraryTests
{
    [TestMethod]
    public async Task TheDemoLibraryOpensWithSoundAndParticipants()
    {
        using var root = new TemporaryDirectory("BardoDemoLibrary");
        var library = Path.Combine(root.Path, "Library");
        await DemoLibrary.SeedAsync(library, DateTimeOffset.Now);
        using var model = new LibraryViewModel(library, new PreferencesStore(root.Path));

        await model.LoadAsync();

        Assert.HasCount(4, model.Rows);
        Assert.AreEqual(0, model.IssueCount);
        Assert.AreEqual("Revisión del diseño para Windows", model.SelectedTitle);
        CollectionAssert.AreEqual(new[] { "Valentina", "Diego" }, model.Speakers.Select(speaker => speaker.DisplayName).ToArray());

        var recording = model.Selected!.Recording;
        var path = await model.RecordingStore.ManagedAudioPathAsync(recording.Id, recording.PlaybackAudioAssets[0].Id);
        var levels = await Waveform.OverviewAsync(new WaveDecoder(), path, recording.Duration!.Value, CancellationToken.None);
        var speakers = Waveform.Speakers(model.SelectedTranscript, recording.Duration.Value, levels.Length);
        Assert.IsGreaterThan(0.5f, levels.Max(), "There is sound to draw");
        CollectionAssert.IsSubsetOf(new[] { 0, 1 }, speakers.Distinct().ToArray(), "Both participants colour the waveform");

        model.Selected = model.Rows.Single(row => row.Title == "Idea para el onboarding");
        Assert.IsTrue(model.HasNoTranscript);
    }

    [TestMethod]
    public void TheDemoRecorderFillsTheWaveform()
    {
        var service = new DemoCaptureService();
        var recorder = new RecorderViewModel(service);
        recorder.Start(CaptureMode.Meeting, null);

        for (var tick = 0; tick < RecorderViewModel.LiveBars; tick++)
        {
            service.Session!.Elapsed += RecorderViewModel.SecondsPerBar;
            recorder.Tick();
        }

        Assert.HasCount(RecorderViewModel.LiveBars, recorder.Live.Microphone);
        Assert.IsGreaterThan(0.5f, recorder.Live.Microphone.Max());
        Assert.IsGreaterThan(0.5f, recorder.Live.System.Max());
    }
}
