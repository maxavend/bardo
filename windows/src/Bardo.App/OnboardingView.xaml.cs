using Bardo.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Bardo.App;

/// <summary>First-run setup: choose Recommended or Precise and download it once.</summary>
public sealed partial class OnboardingView : UserControl
{
    private OnboardingViewModel? _viewModel;

    public OnboardingView()
    {
        InitializeComponent();
    }

    public OnboardingViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            _viewModel = value;
            Bindings.Update();
        }
    }

    private void OnRecommendedChecked(object sender, RoutedEventArgs e)
    {
        if (_viewModel is not null) _viewModel.IsRecommendedChosen = true;
    }

    private void OnPreciseChecked(object sender, RoutedEventArgs e)
    {
        if (_viewModel is not null) _viewModel.IsPreciseChosen = true;
    }

    private async void OnDownload(object sender, RoutedEventArgs e)
    {
        if (_viewModel is not null) await _viewModel.DownloadAsync();
    }

    private void OnPause(object sender, RoutedEventArgs e) => _viewModel?.Pause();

    private void OnClose(object sender, RoutedEventArgs e) => _viewModel?.Close();
}
