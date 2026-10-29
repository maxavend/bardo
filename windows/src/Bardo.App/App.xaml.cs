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
            _window = new MainWindow(await MainWindow.DesignReviewEnvironmentAsync());
            _window.Activate();
            await _window.RunDesignReviewAsync(folder);
            return;
        }
        _window = new MainWindow();
        _window.Activate();
    }
}
