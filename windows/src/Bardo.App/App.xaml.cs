using Microsoft.UI.Xaml;

namespace Bardo.App;

public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (MainWindow.DesignReviewFolder(Environment.GetCommandLineArgs()) is { } folder)
        {
            // In Spanish, whatever language the build machine has.
            Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride = "es";
            System.Globalization.CultureInfo.CurrentCulture = System.Globalization.CultureInfo.GetCultureInfo("es-CL");
            System.Globalization.CultureInfo.CurrentUICulture = System.Globalization.CultureInfo.GetCultureInfo("es-CL");
            _window = new MainWindow(await MainWindow.DesignReviewEnvironmentAsync());
            _window.Activate();
            await _window.RunDesignReviewAsync(folder);
            return;
        }
        _window = new MainWindow();
        _window.Activate();
    }
}
