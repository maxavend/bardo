using Bardo.Audio;
using Bardo.Settings;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Bardo.App;

/// <summary>Settings: your name, the microphone and recording quality, and transcription.</summary>
public sealed partial class SettingsView : UserControl
{
    private SettingsViewModel? _viewModel;

    public SettingsView()
    {
        InitializeComponent();
        Loaded += (_, _) => ShowMicrophones();
    }

    public SettingsViewModel? ViewModel
    {
        get => _viewModel;
        set
        {
            _viewModel = value;
            Bindings.Update();
        }
    }

    /// <summary>The microphones Windows has now; the first entry follows Windows' own choice.</summary>
    private void ShowMicrophones()
    {
        var devices = new List<AudioInputDevice> { new("", Localized.Get("MicrophoneDefault"), IsDefault: true) };
        try
        {
            devices.AddRange(AudioDevices.Microphones());
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            // No audio service: only the default entry is offered.
        }
        MicrophoneBox.ItemsSource = devices;
        MicrophoneBox.SelectedItem = devices.FirstOrDefault(device => device.Id == (_viewModel?.MicrophoneDeviceId ?? "")) ?? devices[0];
    }

    private void OnMicrophoneChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_viewModel is null || MicrophoneBox.SelectedItem is not AudioInputDevice device) return;
        _viewModel.MicrophoneDeviceId = device.Id.Length == 0 ? null : device.Id;
    }

    private async void OnDownloadModels(object sender, RoutedEventArgs e)
    {
        if (_viewModel is not null) await _viewModel.DownloadModelsAsync();
    }

    private void OnCancelDownload(object sender, RoutedEventArgs e) => _viewModel?.CancelDownload();
}
