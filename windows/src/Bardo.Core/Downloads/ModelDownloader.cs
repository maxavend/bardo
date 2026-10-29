using System.Net.Http.Headers;
using System.Security.Cryptography;
using Bardo.Persistence;

namespace Bardo.Downloads;

/// <summary>A file Bardo downloads once and then uses offline, checked against its published hash.</summary>
public sealed record ModelFile(string FileName, Uri Url, long Size, string Sha256);

/// <summary>The models Bardo for Windows uses, and where they come from.</summary>
public static class ModelCatalog
{
    /// <summary>Whisper large-v3 Turbo, quantised to 5 bits: about the size of the macOS app's.</summary>
    public static ModelFile WhisperTurbo { get; } = new(
        "ggml-large-v3-turbo-q5_0.bin",
        new Uri("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"),
        574_041_195,
        "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2");

    /// <summary>Whisper large-v3 in full, quantised to 5 bits.</summary>
    public static ModelFile WhisperLarge { get; } = new(
        "ggml-large-v3-q5_0.bin",
        new Uri("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"),
        1_081_140_203,
        "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1");

    /// <summary>pyannote segmentation 3.0, which finds where voices change.</summary>
    public static ModelFile SpeakerSegmentation { get; } = new(
        "pyannote-segmentation-3.0.onnx",
        new Uri("https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx"),
        5_992_913,
        "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079");

    /// <summary>
    /// NVIDIA NeMo TitaNet small, which tells voices apart. Of the embeddings sherpa-onnx
    /// offers it was the fastest, and as accurate, on a Spanish two-voice dialogue.
    /// </summary>
    public static ModelFile SpeakerEmbedding { get; } = new(
        "nemo_en_titanet_small.onnx",
        new Uri("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx"),
        40_257_283,
        "ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e");

    /// <summary>The folder models live in: <c>%LOCALAPPDATA%\Bardo\Models</c>.</summary>
    public static string DefaultDirectory() =>
        Path.Combine(Path.GetDirectoryName(RecordingStore.DefaultLibraryPath())!, "Models");
}

public sealed class ModelDownloadException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// Downloads models into Bardo's own folder. A download resumes where it stopped, is
/// checked against its size and SHA-256, and only then takes its final name, so a
/// model on disk is always complete.
/// </summary>
public sealed class ModelDownloader(string directory, HttpClient httpClient)
{
    private const int BufferSize = 1 << 20;

    public string Directory { get; } = directory;

    public string PathFor(ModelFile model) => Path.Combine(Directory, model.FileName);

    public bool IsInstalled(ModelFile model)
    {
        var path = PathFor(model);
        return File.Exists(path) && new FileInfo(path).Length == model.Size;
    }

    /// <summary>Downloads every missing model, reporting the fraction done across all of them.</summary>
    public async Task EnsureAsync(IReadOnlyList<ModelFile> models, IProgress<double>? progress, CancellationToken cancellationToken)
    {
        var total = models.Sum(model => model.Size);
        long done = 0;
        foreach (var model in models)
        {
            if (!IsInstalled(model))
            {
                var start = done;
                await DownloadAsync(model, new Progress<long>(bytes => progress?.Report((double)(start + bytes) / total)), cancellationToken).ConfigureAwait(false);
            }
            done += model.Size;
            progress?.Report((double)done / total);
        }
    }

    public void Remove(ModelFile model)
    {
        File.Delete(PathFor(model));
        File.Delete(PartialPath(model));
    }

    private async Task DownloadAsync(ModelFile model, IProgress<long> progress, CancellationToken cancellationToken)
    {
        DurableFile.CreatePrivateDirectory(Directory);
        var partial = PartialPath(model);
        var existing = File.Exists(partial) ? new FileInfo(partial).Length : 0;
        if (existing > model.Size)
        {
            File.Delete(partial);
            existing = 0;
        }

        if (existing < model.Size)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, model.Url);
            if (existing > 0) request.Headers.Range = new RangeHeaderValue(existing, null);
            using var response = await httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw new ModelDownloadException($"{model.FileName}: HTTP {(int)response.StatusCode}");
            }
            // A server that ignores the range sends the whole file again.
            var append = existing > 0 && response.StatusCode == System.Net.HttpStatusCode.PartialContent;
            if (!append) existing = 0;

            await using var source = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            await using var target = new FileStream(partial, append ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, BufferSize, useAsync: true);
            var buffer = new byte[BufferSize];
            int read;
            while ((read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
            {
                await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                existing += read;
                progress.Report(existing);
            }
            await target.FlushAsync(cancellationToken).ConfigureAwait(false);
        }

        if (new FileInfo(partial).Length != model.Size || !await HasHashAsync(partial, model.Sha256, cancellationToken).ConfigureAwait(false))
        {
            File.Delete(partial);
            throw new ModelDownloadException($"{model.FileName}: the download was damaged. Try again.");
        }
        DurableFile.Rename(partial, PathFor(model));
    }

    private string PartialPath(ModelFile model) => PathFor(model) + ".partial";

    private static async Task<bool> HasHashAsync(string path, string expected, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, BufferSize, useAsync: true);
        var hash = await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false);
        return Convert.ToHexStringLower(hash) == expected;
    }
}
