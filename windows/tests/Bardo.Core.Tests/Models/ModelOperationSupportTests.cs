using System.Collections.Concurrent;
using System.Diagnostics;
using Bardo.Models;

namespace Bardo.Tests.Models;

[TestClass]
public sealed class ManagedModelStateTests
{
    [TestMethod]
    public void ManagedModelListsOnlyTranscriptionResources() =>
        CollectionAssert.AreEqual(
            new[] { ManagedModel.WhisperTurbo, ManagedModel.WhisperLarge, ManagedModel.SpeakerIdentification },
            Enum.GetValues<ManagedModel>());

    [TestMethod]
    public void ManagedModelStateIsEquatableAcrossAssociatedValues()
    {
        Assert.AreEqual<ManagedModelState>(new ManagedModelState.NotInstalled(), new ManagedModelState.NotInstalled());
        Assert.AreEqual<ManagedModelState>(new ManagedModelState.Downloading(0.5), new ManagedModelState.Downloading(0.5));
        Assert.AreEqual<ManagedModelState>(new ManagedModelState.Preparing(0.75), new ManagedModelState.Preparing(0.75));
        Assert.AreEqual<ManagedModelState>(new ManagedModelState.Installed(), new ManagedModelState.Installed());
        Assert.AreEqual<ManagedModelState>(new ManagedModelState.Failed("network"), new ManagedModelState.Failed("network"));
        Assert.AreNotEqual<ManagedModelState>(new ManagedModelState.Downloading(0.5), new ManagedModelState.Preparing(0.5));
        Assert.AreNotEqual<ManagedModelState>(new ManagedModelState.Failed("network"), new ManagedModelState.Failed("disk"));
    }

    [TestMethod]
    public void ProgressOutsideZeroToOneIsClamped()
    {
        Assert.AreEqual(0, ModelSetupProgressSnapshot.Clamped(double.NaN));
        Assert.AreEqual(0, ModelSetupProgressSnapshot.Clamped(-0.5));
        Assert.AreEqual(1, ModelSetupProgressSnapshot.Clamped(1.5));
        Assert.AreEqual(0.25, ModelSetupProgressSnapshot.Clamped(0.25));
    }
}

[TestClass]
public sealed class ModelOperationSupportTests
{
    [TestMethod]
    public void LateProgressObserversReceiveTheLatestValue()
    {
        var fanOut = new ProgressFanOut<double>();
        fanOut.Send(0.4);
        var received = new List<double>();
        var id = fanOut.Add(received.Add);
        fanOut.Send(0.7);
        fanOut.Remove(id);
        fanOut.Send(0.9);

        CollectionAssert.AreEqual(new[] { 0.4, 0.7 }, received);
    }

    [TestMethod]
    public async Task CancelledWaiterReturnsPromptlyWhileWorkKeepsRunning()
    {
        var workCancelled = false;
        var operation = new SingleFlightOperation<int, double>(async (_, token) =>
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(2), token);
            }
            catch (OperationCanceledException)
            {
                workCancelled = true;
                throw;
            }
            return 42;
        });
        using var waiterCancellation = new CancellationTokenSource();
        var waiter = operation.RunAsync(cancellationToken: waiterCancellation.Token);
        var other = operation.RunAsync();
        await Task.Delay(50);
        var start = Stopwatch.StartNew();
        await waiterCancellation.CancelAsync();

        await Assert.ThrowsAsync<OperationCanceledException>(() => waiter);
        Assert.IsLessThan(TimeSpan.FromMilliseconds(500), start.Elapsed);
        Assert.IsFalse(workCancelled, "Another caller still needs the work");
        Assert.AreEqual(42, await other);
    }

    [TestMethod]
    public async Task ConcurrentRequestsShareOneDownload()
    {
        var downloads = 0;
        var operation = new SingleFlightOperation<string, double>(async (progress, token) =>
        {
            Interlocked.Increment(ref downloads);
            await Task.Delay(200, token);
            progress(1);
            return "models/large-v3-turbo";
        });
        var reported = new ConcurrentBag<double>();

        var first = operation.RunAsync(reported.Add);
        var second = operation.RunAsync(reported.Add);
        var results = await Task.WhenAll(first, second);

        Assert.AreEqual(results[0], results[1]);
        Assert.AreEqual(1, downloads, "Concurrent callers must not download into the same folder twice");
        Assert.IsFalse(operation.IsRunning);
        Assert.HasCount(2, reported, "Every caller hears the shared progress");
    }

    [TestMethod]
    public async Task OneCallerCancellingDoesNotStopADownloadAnotherCallerNeeds()
    {
        var downloads = 0;
        var operation = new SingleFlightOperation<string, double>(async (_, token) =>
        {
            Interlocked.Increment(ref downloads);
            await Task.Delay(300, token);
            return "models/large-v3-turbo";
        });

        // Setup pauses while a transcription keeps waiting for the same download.
        using var setupCancellation = new CancellationTokenSource();
        var setup = operation.RunAsync(cancellationToken: setupCancellation.Token);
        var transcription = operation.RunAsync();
        await Task.Delay(80);
        await setupCancellation.CancelAsync();

        await Assert.ThrowsAsync<OperationCanceledException>(() => setup, "The paused caller must see its cancellation");
        Assert.AreEqual("models/large-v3-turbo", await transcription);
        Assert.AreEqual(1, downloads);
    }

    [TestMethod]
    public async Task CancellingADownloadLetsTheNextRequestStartCleanly()
    {
        var downloads = 0;
        var firstStopped = new TaskCompletionSource();
        var operation = new SingleFlightOperation<string, double>(async (_, token) =>
        {
            var attempt = Interlocked.Increment(ref downloads);
            if (attempt == 1)
            {
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(10), token);
                }
                finally
                {
                    firstStopped.SetResult();
                }
            }
            return "models/large-v3-turbo";
        });

        using var pause = new CancellationTokenSource();
        var paused = operation.RunAsync(cancellationToken: pause.Token);
        await Task.Delay(100);
        await pause.CancelAsync();
        await Assert.ThrowsAsync<OperationCanceledException>(() => paused, "Pausing must cancel the download");

        var resumed = await operation.RunAsync();

        Assert.IsTrue(firstStopped.Task.IsCompleted, "The stopped download finished unwinding before the next one started");
        Assert.AreEqual("models/large-v3-turbo", resumed);
        Assert.AreEqual(2, downloads);
        Assert.IsFalse(operation.IsRunning, "A finished download must not keep the model marked in use");
    }

    [TestMethod]
    public async Task AFailedOperationReachesEveryCallerAndCanBeRetried()
    {
        var attempts = 0;
        var operation = new SingleFlightOperation<int, double>(async (_, token) =>
        {
            await Task.Delay(50, token);
            if (Interlocked.Increment(ref attempts) == 1) throw new IOException("offline");
            return 7;
        });

        var first = operation.RunAsync();
        var second = operation.RunAsync();
        await Assert.ThrowsExactlyAsync<IOException>(() => first);
        await Assert.ThrowsExactlyAsync<IOException>(() => second);

        Assert.AreEqual(7, await operation.RunAsync());
        Assert.AreEqual(2, attempts);
    }
}

[TestClass]
public sealed class ModelUseTrackerTests
{
    [TestMethod]
    public void AModelInUseCannotBeRemoved()
    {
        using var tracker = new ModelUseTracker(() => { });
        var transcription = tracker.Begin();

        Assert.IsTrue(tracker.IsInUse);
        Assert.ThrowsExactly<ModelInUseException>(() => tracker.BeginReset());

        transcription.Dispose();
        using (tracker.BeginReset())
        {
            Assert.ThrowsExactly<ModelInUseException>(() => tracker.Begin(), "Nothing starts while the files are being removed");
        }
        Assert.IsFalse(tracker.IsInUse);
    }

    [TestMethod]
    public async Task AnIdleModelIsLetGoButNeverWhileInUse()
    {
        var unloads = 0;
        using var tracker = new ModelUseTracker(() => Interlocked.Increment(ref unloads), TimeSpan.FromMilliseconds(100));

        var transcription = tracker.Begin();
        tracker.MarkLoaded();
        await Task.Delay(300);
        Assert.AreEqual(0, unloads, "A model in use is never unloaded");

        transcription.Dispose();
        transcription.Dispose();
        for (var attempt = 0; attempt < 100 && Volatile.Read(ref unloads) == 0; attempt++) await Task.Delay(20);
        Assert.AreEqual(1, unloads);
        Assert.IsFalse(tracker.IsInUse);
    }

    [TestMethod]
    public async Task NewWorkKeepsTheModelLoaded()
    {
        var unloads = 0;
        using var tracker = new ModelUseTracker(() => Interlocked.Increment(ref unloads), TimeSpan.FromMilliseconds(150));
        tracker.MarkLoaded();

        using (tracker.Begin())
        {
            await Task.Delay(300);
        }

        Assert.AreEqual(0, unloads, "The idle time starts over when the work ends");
    }
}

[TestClass]
public sealed class PipelineStringsTests
{
    [TestMethod]
    public void ErrorsAreWrittenInTheAppsLanguage()
    {
        var original = System.Globalization.CultureInfo.CurrentUICulture;
        try
        {
            System.Globalization.CultureInfo.CurrentUICulture = System.Globalization.CultureInfo.GetCultureInfo("es-CL");
            Assert.AreEqual("No se encontró voz para transcribir en este audio.", Bardo.Transcription.TranscriptionException.EmptyTranscription().Message);
            Assert.StartsWith("Este recurso se está usando ahora.", new ModelInUseException().Message);

            System.Globalization.CultureInfo.CurrentUICulture = System.Globalization.CultureInfo.GetCultureInfo("en-US");
            Assert.AreEqual(
                "Speaker identification completed without finding any speaker activity.",
                Bardo.Diarization.DiarizationException.NoSpeakerActivity().Message);
        }
        finally
        {
            System.Globalization.CultureInfo.CurrentUICulture = original;
        }
    }
}
