using System.Numerics;
using Bardo.Capture;
using Bardo.Library;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI;

namespace Bardo.App.Controls;

/// <summary>
/// The colours that tell participants apart, shared by the waveform and the participant list.
/// The first is the person's accent colour, as in Windows' own apps; the rest are Fluent
/// colours that read on light and dark.
/// </summary>
internal static class SpeakerPalette
{
    private static readonly Color[] Others =
    [
        Color.FromArgb(255, 0, 183, 195),
        Color.FromArgb(255, 247, 99, 12),
        Color.FromArgb(255, 135, 100, 184),
        Color.FromArgb(255, 16, 137, 62),
        Color.FromArgb(255, 227, 0, 140),
        Color.FromArgb(255, 202, 80, 16),
    ];

    public static Color Accent =>
        Application.Current.Resources.TryGetValue("SystemAccentColor", out var value) && value is Color color
            ? color
            : Color.FromArgb(255, 0, 120, 212);

    /// <summary>Unnamed sound in a transcribed recording, and every bar of one that is not.</summary>
    public static Color Neutral(ElementTheme theme) =>
        theme == ElementTheme.Light ? Color.FromArgb(255, 112, 112, 112) : Color.FromArgb(255, 160, 160, 160);

    public static Color For(int speaker) => speaker <= 0 ? Accent : Others[(speaker - 1) % Others.Length];
}

/// <summary>
/// A waveform in the manner of Windows 11's Sound Recorder: rounded vertical bars drawn by
/// the compositor. As an overview it shows a whole conversation coloured by participant,
/// with what has played in full colour, and seeks where it is clicked; live, it scrolls
/// from right to left as a recording grows, with its moments and sections marked above.
/// </summary>
public sealed partial class WaveformView : Grid
{
    private const float BarWidth = 3;
    private const float BarGap = 2;
    private const float MarkDiameter = 6;
    private const float UnplayedOpacity = 0.4f;

    private readonly Compositor _compositor;
    private readonly ShapeVisual _shapes;
    private readonly List<(CompositionSpriteShape Shape, CompositionRoundedRectangleGeometry Geometry)> _bars = [];
    private readonly List<CompositionSpriteShape> _marks = [];
    private readonly Dictionary<Color, CompositionColorBrush> _brushes = [];
    private float[] _levels = [];
    private int[] _speakers = [];
    private float[] _secondary = [];
    private float[] _drawnLevels = [];
    private float[] _drawnSecondary = [];
    private IReadOnlyList<double> _markFractions = [];
    private double _progress = 1;
    private bool _isLive;

    public WaveformView()
    {
        Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Colors.Transparent);
        _compositor = ElementCompositionPreview.GetElementVisual(this).Compositor;
        _shapes = _compositor.CreateShapeVisual();
        ElementCompositionPreview.SetElementChildVisual(this, _shapes);
        SizeChanged += (_, _) => Redraw();
        ActualThemeChanged += (_, _) =>
        {
            _brushes.Clear();
            Redraw();
        };
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        PointerPressed += OnPointerPressed;
        PointerMoved += OnPointerMoved;
        PointerReleased += OnPointerReleased;
        KeyDown += OnKeyDown;
    }

    /// <summary>Raised when the overview is clicked or dragged, with where in the recording, from 0 to 1.</summary>
    public event EventHandler<double>? SeekRequested;

    /// <summary>Raised by the arrow keys, with how far to move in seconds.</summary>
    public event EventHandler<double>? StepRequested;

    /// <summary>Shows a whole recording: its loudness, and who speaks in each stretch.</summary>
    public void ShowOverview(float[] levels, int[] speakers)
    {
        _isLive = false;
        _levels = levels;
        _speakers = speakers;
        _secondary = [];
        _markFractions = [];
        ProtectedCursor = levels.Length > 0 ? InputSystemCursor.Create(InputSystemCursorShape.Hand) : null;
        Redraw();
    }

    public void Clear() => ShowOverview([], []);

    /// <summary>How much has played, from 0 to 1; what is ahead is drawn fainter.</summary>
    public double Progress
    {
        get => _progress;
        set
        {
            var clamped = Math.Clamp(value, 0, 1);
            if (Math.Abs(clamped - _progress) < 1e-4) return;
            _progress = clamped;
            Recolor();
        }
    }

    /// <summary>
    /// Shows the last seconds of a recording in progress. In a meeting each bar takes the
    /// colour of whichever source was louder: the accent for the microphone, the second
    /// participant colour for the computer's audio.
    /// </summary>
    public void ShowLive(LiveWaveform live)
    {
        _isLive = true;
        var hasMicrophone = live.Microphone.Any(level => level > 0);
        _levels = hasMicrophone || live.System.Length == 0 ? live.Microphone : live.System;
        _secondary = hasMicrophone ? live.System : [];
        _speakers = [];
        _progress = 1;
        var window = RecorderViewModel.LiveBars * live.SecondsPerBar;
        _markFractions = [.. live.Marks.Select(seconds => 1 - (live.Elapsed - seconds) / window)];
        Redraw();
    }

    private void Redraw()
    {
        var width = (float)ActualWidth;
        var height = (float)ActualHeight;
        _shapes.Size = new Vector2(width, height);
        var slots = Math.Max(0, (int)((width + BarGap) / (BarWidth + BarGap)));
        int count;
        if (_isLive)
        {
            // The whole window, twelve seconds, spans the width; a recording that has just
            // started fills it from the right, so marks stay over the moment they mark.
            var heard = Math.Min(_levels.Length, RecorderViewModel.LiveBars);
            count = (int)Math.Round(slots * (double)heard / RecorderViewModel.LiveBars);
            _drawnLevels = Waveform.Bars(_levels, count);
            _drawnSecondary = _secondary.Length > 0 ? Waveform.Bars(_secondary, count) : [];
        }
        else
        {
            count = slots;
            _drawnLevels = Waveform.Bars(_levels, count);
            _drawnSecondary = [];
        }

        while (_bars.Count < count)
        {
            var geometry = _compositor.CreateRoundedRectangleGeometry();
            geometry.CornerRadius = new Vector2(BarWidth / 2);
            var shape = _compositor.CreateSpriteShape(geometry);
            _shapes.Shapes.Add(shape);
            _bars.Add((shape, geometry));
        }
        while (_bars.Count > count)
        {
            _shapes.Shapes.Remove(_bars[^1].Shape);
            _bars.RemoveAt(_bars.Count - 1);
        }

        // Live bars sit at the right, the newest last, like a recorder's tape.
        var origin = _isLive ? width - count * (BarWidth + BarGap) + BarGap : 0;
        var drawable = height - (_isLive ? MarkDiameter * 2 : 0);
        for (var index = 0; index < count; index++)
        {
            var level = Math.Max(At(_drawnLevels, index), At(_drawnSecondary, index));
            var barHeight = Math.Max(BarWidth, level * drawable * 0.92f);
            var (shape, geometry) = _bars[index];
            geometry.Size = new Vector2(BarWidth, barHeight);
            shape.Offset = new Vector2(origin + index * (BarWidth + BarGap), height - drawable + (drawable - barHeight) / 2);
        }
        Recolor();
        DrawMarks(width);
    }

    private void Recolor()
    {
        var count = _bars.Count;
        var speakers = _isLive ? Array.Empty<int>() : SpeakersFor(count);
        var transcribed = _speakers.Any(speaker => speaker >= 0);
        for (var index = 0; index < count; index++)
        {
            Color color;
            if (_isLive)
            {
                color = SpeakerPalette.For(At(_drawnSecondary, index) > At(_drawnLevels, index) ? 1 : 0);
            }
            else
            {
                var speaker = index < speakers.Length ? speakers[index] : -1;
                color = speaker >= 0 ? SpeakerPalette.For(speaker) : transcribed ? SpeakerPalette.Neutral(ActualTheme) : SpeakerPalette.Accent;
                var played = (index + 0.5) / Math.Max(1, count) <= _progress;
                if (!played) color = Color.FromArgb((byte)(255 * UnplayedOpacity), color.R, color.G, color.B);
            }
            _bars[index].Shape.FillBrush = Brush(color);
        }
    }

    private static float At(float[] values, int index) => index < values.Length ? values[index] : 0;

    private void DrawMarks(float width)
    {
        var visible = _markFractions.Where(fraction => fraction is >= 0 and <= 1).ToList();
        while (_marks.Count < visible.Count)
        {
            var geometry = _compositor.CreateEllipseGeometry();
            geometry.Radius = new Vector2(MarkDiameter / 2);
            var shape = _compositor.CreateSpriteShape(geometry);
            shape.FillBrush = Brush(SpeakerPalette.Accent);
            _shapes.Shapes.Add(shape);
            _marks.Add(shape);
        }
        while (_marks.Count > visible.Count)
        {
            _shapes.Shapes.Remove(_marks[^1]);
            _marks.RemoveAt(_marks.Count - 1);
        }
        for (var index = 0; index < visible.Count; index++)
        {
            _marks[index].Offset = new Vector2((float)(visible[index] * width), MarkDiameter / 2);
        }
    }

    /// <summary>Which participant each of <paramref name="count"/> bars belongs to: the one speaking most of its span.</summary>
    private int[] SpeakersFor(int count)
    {
        if (_speakers.Length == 0 || count == 0) return [];
        var bars = new int[count];
        for (var bar = 0; bar < count; bar++)
        {
            var start = (int)((long)bar * _speakers.Length / count);
            var end = Math.Max(start + 1, (int)((long)(bar + 1) * _speakers.Length / count));
            bars[bar] = _speakers[start..Math.Min(end, _speakers.Length)]
                .GroupBy(speaker => speaker)
                .OrderByDescending(group => group.Count())
                .ThenByDescending(group => group.Key)
                .First().Key;
        }
        return bars;
    }

    private CompositionColorBrush Brush(Color color)
    {
        if (!_brushes.TryGetValue(color, out var brush)) _brushes[color] = brush = _compositor.CreateColorBrush(color);
        return brush;
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_isLive || _levels.Length == 0) return;
        CapturePointer(e.Pointer);
        Focus(FocusState.Pointer);
        Seek(e);
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_isLive && PointerCaptures?.Count > 0) Seek(e);
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        ReleasePointerCapture(e.Pointer);
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_isLive) return;
        var step = e.Key switch
        {
            VirtualKey.Left => -5,
            VirtualKey.Right => 5,
            VirtualKey.PageDown => 30,
            VirtualKey.PageUp => -30,
            _ => 0,
        };
        if (step == 0) return;
        StepRequested?.Invoke(this, step);
        e.Handled = true;
    }

    private void Seek(PointerRoutedEventArgs e)
    {
        if (ActualWidth <= 0) return;
        var x = e.GetCurrentPoint(this).Position.X;
        SeekRequested?.Invoke(this, Math.Clamp(x / ActualWidth, 0, 1));
    }
}
