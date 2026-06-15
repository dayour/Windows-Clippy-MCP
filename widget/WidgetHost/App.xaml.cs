using System;
using System.Windows;

namespace WidgetHost;

public partial class App : System.Windows.Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        try
        {
            var options = WidgetHost.MainWindow.ParseArguments(e.Args);
            var benchWindow = new WidgetHost.MainWindow(options);
            var launcherWindow = new WidgetHost.LauncherWindow(options, benchWindow);
            MainWindow = launcherWindow;
            launcherWindow.Show();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(
                ex.Message,
                "Windows Clippy Widget",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(1);
        }
    }
}
