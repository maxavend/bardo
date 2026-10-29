using System.Buffers.Binary;

namespace Bardo.Capture;

/// <summary>The format of a PCM or IEEE-float WAV file.</summary>
public readonly record struct WaveFormatInfo(int SampleRate, int Channels, int BitsPerSample, bool IsFloat)
{
    public int BlockAlign => Channels * BitsPerSample / 8;
}

/// <summary>
/// Reads and repairs the WAV files Bardo stages while recording. A capture writes its
/// header sizes about once a second; a crash in between leaves them short, and repair
/// sets them from the file's real length so no captured audio is lost.
/// </summary>
public static class WaveFile
{
    public static WaveFormatInfo ReadFormat(string path) => Inspect(path).Format;

    /// <summary>Seconds of audio the file holds, measured from its length rather than its header.</summary>
    public static double Duration(string path)
    {
        var (format, dataOffset, _) = Inspect(path);
        var bytes = new FileInfo(path).Length - dataOffset;
        return format.BlockAlign == 0 ? 0 : (double)(bytes / format.BlockAlign) / format.SampleRate;
    }

    /// <summary>Sets the RIFF and data sizes from the file's length. Returns true when they were wrong.</summary>
    public static bool Repair(string path)
    {
        var (format, dataOffset, declared) = Inspect(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        var available = stream.Length - dataOffset;
        // A frame cut short by the crash is dropped.
        var dataBytes = available - available % Math.Max(1, format.BlockAlign);
        if (dataBytes > uint.MaxValue - dataOffset) dataBytes = uint.MaxValue - dataOffset;
        if (declared == dataBytes && stream.Length == dataOffset + dataBytes) return false;

        stream.SetLength(dataOffset + dataBytes);
        Span<byte> size = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(size, (uint)(dataOffset + dataBytes - 8));
        stream.Position = 4;
        stream.Write(size);
        BinaryPrimitives.WriteUInt32LittleEndian(size, (uint)dataBytes);
        stream.Position = dataOffset - 4;
        stream.Write(size);
        stream.Flush(flushToDisk: true);
        return true;
    }

    /// <summary>The samples of a 16-bit or float WAV, mixed down to mono.</summary>
    public static float[] ReadMonoSamples(string path, out int sampleRate)
    {
        var (format, dataOffset, _) = Inspect(path);
        sampleRate = format.SampleRate;
        var bytes = File.ReadAllBytes(path).AsSpan((int)dataOffset);
        var frames = bytes.Length / format.BlockAlign;
        var samples = new float[frames];
        var bytesPerSample = format.BitsPerSample / 8;
        for (var frame = 0; frame < frames; frame++)
        {
            float sum = 0;
            for (var channel = 0; channel < format.Channels; channel++)
            {
                var sample = bytes.Slice(frame * format.BlockAlign + channel * bytesPerSample, bytesPerSample);
                sum += format switch
                {
                    { IsFloat: true, BitsPerSample: 32 } => BinaryPrimitives.ReadSingleLittleEndian(sample),
                    { BitsPerSample: 16 } => BinaryPrimitives.ReadInt16LittleEndian(sample) / 32768f,
                    { BitsPerSample: 24 } => ((sample[0] << 8) | (sample[1] << 16) | (sample[2] << 24)) / 2147483648f,
                    { BitsPerSample: 32 } => BinaryPrimitives.ReadInt32LittleEndian(sample) / 2147483648f,
                    _ => throw new InvalidDataException("Unsupported WAV sample format."),
                };
            }
            samples[frame] = sum / format.Channels;
        }
        return samples;
    }

    private static (WaveFormatInfo Format, long DataOffset, long DeclaredDataBytes) Inspect(string path)
    {
        using var stream = File.OpenRead(path);
        using var reader = new BinaryReader(stream);
        if (stream.Length < 12 || new string(reader.ReadChars(4)) != "RIFF") throw new InvalidDataException("Not a RIFF file.");
        reader.ReadUInt32();
        if (new string(reader.ReadChars(4)) != "WAVE") throw new InvalidDataException("Not a WAVE file.");

        WaveFormatInfo? format = null;
        while (stream.Position + 8 <= stream.Length)
        {
            var id = new string(reader.ReadChars(4));
            var size = reader.ReadUInt32();
            if (id == "fmt ")
            {
                var tag = reader.ReadUInt16();
                var channels = reader.ReadUInt16();
                var rate = reader.ReadInt32();
                reader.ReadInt32();
                reader.ReadUInt16();
                var bits = reader.ReadUInt16();
                if (tag == 0xFFFE && size >= 40)
                {
                    reader.ReadBytes(8);
                    tag = reader.ReadUInt16();
                    stream.Position += size - 26;
                }
                else
                {
                    stream.Position += size - 16;
                }
                format = new WaveFormatInfo(rate, channels, bits, tag == 3);
            }
            else if (id == "data")
            {
                return (format ?? throw new InvalidDataException("WAV data before its format."), stream.Position, size);
            }
            else
            {
                stream.Position += size + size % 2;
            }
        }
        throw new InvalidDataException("WAV file without data.");
    }
}
