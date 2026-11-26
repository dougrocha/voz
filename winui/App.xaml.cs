using Microsoft.UI.Xaml;

namespace VozUi;

public partial class App : Application
{
    Window? window;

    public App()
    {
        InitializeComponent();
        // There's no console, so crashes (XAML load errors included) go to %TEMP%\voz-ui.log.
        UnhandledException += (_, e) => System.IO.File.WriteAllText(
            System.IO.Path.Combine(System.IO.Path.GetTempPath(), "voz-ui.log"), e.Exception.ToString());
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        window.Activate();
    }
}
