using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using Bardo.Domain;
using Bardo.Downloads;
using Bardo.Settings;

namespace Bardo.Tests.Settings;

[TestClass]
public sealed class SettingsAndDownloadTests
{
    private TemporaryDirectory _root = null!;

    [TestInitialize]
    public void SetUp() => _root = new TemporaryDirectory("BardoSettings");

    [TestCleanup]
    public void TearDown() => _root.Dispose();

    private static ModelFile Model(byte[] content, string name = "model.bin") =>
        new(name, new Uri($"https://example.test/{name}"), content.Length, Convert.ToHexStringLower(SHA256.HashData(content)));

    [TestMethod]
    public async Task ADownloadIsCheckedAndOnlyThenNamed()
    {
        var content = RandomNumberGenerator.GetBytes(300_000);
        var model = Model(content);
        using var http = new HttpClient(new FileServer(content));
        var downloader = new ModelDownloader(_root.Path, http);
        var progress = new List<double>();

        await downloader.EnsureAsync([model], new Progress<double>(progress.Add), CancellationToken.None);

        Assert.IsTrue(downloader.IsInstalled(model));
        CollectionAssert.AreEqual(content, await File.ReadAllBytesAsync(downloader.PathFor(model)));
        Assert.IsFalse(File.Exists(downloader.PathFor(model) + ".partial"));
    }

    [TestMethod]
    public async Task AnInterruptedDownloadResumesWhereItStopped()
    {
        var content = RandomNumberGenerator.GetBytes(200_000);
        var model = Model(content);
        await File.WriteAllBytesAsync(Path.Combine(_root.Path, model.FileName + ".partial"), content[..120_000]);
        var server = new FileServer(content);
        using var http = new HttpClient(server);

        await new ModelDownloader(_root.Path, http).EnsureAsync([model], null, CancellationToken.None);

        Assert.AreEqual(120_000, server.LastRangeStart, "Only the rest is requested");
        CollectionAssert.AreEqual(content, await File.ReadAllBytesAsync(Path.Combine(_root.Path, model.FileName)));
    }

    [TestMethod]
    public async Task ADamagedDownloadIsDiscarded()
    {
        var content = RandomNumberGenerator.GetBytes(50_000);
        var model = Model(content) with { Sha256 = new string('0', 64) };
        using var http = new HttpClient(new FileServer(content));
        var downloader = new ModelDownloader(_root.Path, http);

        await Assert.ThrowsExactlyAsync<ModelDownloadException>(() => downloader.EnsureAsync([model], null, CancellationToken.None));

        Assert.IsFalse(downloader.IsInstalled(model));
        Assert.IsFalse(File.Exists(downloader.PathFor(model) + ".partial"));
    }

    [TestMethod]
    public void SettingsAreSavedAsTheyChange()
    {
        var preferences = new PreferencesStore(_root.Path);
        using var http = new HttpClient();
        using var settings = new SettingsViewModel(preferences, new ModelSetup(new ModelDownloader(Path.Combine(_root.Path, "Models"), http)));

        settings.LocalName = "  Maxi ";
        settings.AudioQualityIndex = (int)AudioQualityPreset.Compact;
        settings.KeepsLossless = true;
        settings.TranscribesTracksApart = false;
        settings.TranscriptionQualityIndex = (int)TranscriptionQuality.Precise;

        var saved = new PreferencesStore(_root.Path).Current;
        Assert.AreEqual("Maxi", saved.LocalName);
        Assert.AreEqual(new AudioEncoding(AudioQualityPreset.Compact, AudioStorageFormat.Wav), saved.Encoding);
        Assert.AreEqual(TranscriptionTrackMode.Mix, saved.TrackMode);
        Assert.AreEqual(TranscriptionQuality.Precise, saved.TranscriptionQuality);
        Assert.IsTrue(settings.IsTranscriptionMissing);
        StringAssert.EndsWith(settings.TranscriptionModelSize, "GB", "Large is over a gigabyte");

        settings.LocalName = "   ";
        Assert.IsNull(new PreferencesStore(_root.Path).Current.LocalName, "A blank name goes back to “You”");
    }

    /// <summary>Serves one file, honouring byte ranges like a CDN.</summary>
    private sealed class FileServer(byte[] content) : HttpMessageHandler
    {
        public long? LastRangeStart { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var start = request.Headers.Range?.Ranges.First().From ?? 0;
            LastRangeStart = request.Headers.Range is null ? null : start;
            var response = new HttpResponseMessage(start > 0 ? HttpStatusCode.PartialContent : HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(content, (int)start, content.Length - (int)start),
            };
            if (start > 0) response.Content.Headers.ContentRange = new ContentRangeHeaderValue(start, content.Length - 1, content.Length);
            return Task.FromResult(response);
        }
    }
}
