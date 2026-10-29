using Bardo.App.Controls;
using Bardo.Library;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.ApplicationModel.Resources;

namespace Bardo.App;

/// <summary>Conversions for x:Bind.</summary>
internal static class Bind
{
    public static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility Hide(bool value) => value ? Visibility.Collapsed : Visibility.Visible;

    public static Visibility ShowBoth(bool first, bool second) => Show(first && second);

    public static Visibility ShowEither(bool first, bool second) => Show(first || second);

    public static bool Not(bool value) => !value;

    public static Microsoft.UI.Xaml.Media.SolidColorBrush SpeakerBrush(int index) => new(SpeakerPalette.For(index));

    public static Microsoft.UI.Xaml.Media.SolidColorBrush SourceBrush(bool isSystemAudio) => new(SpeakerPalette.For(isSystemAudio ? 1 : 0));

    public static InfoBarSeverity Severity(LibraryNotice? notice) => notice is { IsError: true } ? InfoBarSeverity.Error : InfoBarSeverity.Success;

    public static string Message(LibraryNotice? notice) => notice?.Message ?? "";

    /// <summary>Segoe Fluent Icons: a filled star for a favourite, an outline otherwise.</summary>
    public static string Star(bool isFavorite) => isFavorite ? "" : "";
}

/// <summary>Interface text from the app's resources, for what XAML cannot name with x:Uid.</summary>
internal static class Localized
{
    private static readonly ResourceLoader Loader = new();

    public static string Get(string name) => Loader.GetString(name) is { Length: > 0 } text ? text : name;

    public static string Format(string name, params object[] arguments) =>
        string.Format(System.Globalization.CultureInfo.CurrentCulture, Get(name), arguments);
}
