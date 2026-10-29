using System.Net;
using System.Security.Cryptography;
using Bardo.Downloads;
using Bardo.Settings;

namespace Bardo.Tests.Settings;

[TestClass]
public sealed class OnboardingTests
{
    private TemporaryDirectory _root = null!;

    [TestInitialize]
    public void SetUp() => _root = new TemporaryDirectory("BardoOnboarding");

    [TestCleanup]
    public void TearDown() => _root.Dispose();

    private (OnboardingViewModel Onboarding, SettingsViewModel Settings, PreferencesStore Preferences) Make(HttpMessageHandler handler)
    {
        var preferences = new PreferencesStore(_root.Path);
        var settings = new SettingsViewModel(preferences, new ModelSetup(new ModelDownloader(Path.Combine(_root.Path, "Models"), new HttpClient(handler))));
        return (new OnboardingViewModel(preferences, settings), settings, preferences);
    }

    [TestMethod]
    public void FirstLaunchOffersRecommendedWithItsSize()
    {
        var (onboarding, _, _) = Make(new Failing());

        Assert.IsTrue(onboarding.IsOpen);
        Assert.IsTrue(onboarding.IsChoosing);
        Assert.IsTrue(onboarding.IsRecommendedChosen);
        StringAssert.EndsWith(onboarding.RecommendedSize, "MB");
        StringAssert.EndsWith(onboarding.PreciseSize, "GB");

        onboarding.IsPreciseChosen = true;
        Assert.IsFalse(onboarding.IsRecommendedChosen);
    }

    [TestMethod]
    public async Task AFailedDownloadCanBeRetriedAndSetupSetAside()
    {
        var (onboarding, _, preferences) = Make(new Failing());

        await onboarding.DownloadAsync();

        Assert.IsTrue(onboarding.HasFailed);
        Assert.IsNotNull(onboarding.Error);
        Assert.IsFalse(preferences.Current.HasFinishedSetup);

        onboarding.Close();
        Assert.IsFalse(onboarding.IsOpen);
        Assert.IsTrue(preferences.Current.HasFinishedSetup);
        Assert.IsFalse(Make(new Failing()).Onboarding.IsOpen, "Offered only once");
    }

    [TestMethod]
    public void AReviewCanShowTheDownload()
    {
        var (onboarding, _, _) = Make(new Failing());

        onboarding.Preview(OnboardingState.Downloading, 0.42);

        Assert.IsTrue(onboarding.IsDownloading);
        Assert.IsTrue(onboarding.ShowsProgress);
        Assert.AreEqual(0.42, onboarding.Progress, 1e-9);
    }

    private sealed class Failing : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable));
    }
}
