using System;
using System.Windows;

namespace BrowserHost;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        try
        {
            var options = BrowserHost.MainWindow.ParseArguments(e.Args);
            var window = new BrowserHost.MainWindow(options);
            MainWindow = window;
            if (options.HwndMode)
            {
                window.Visibility = Visibility.Hidden;
                window.ShowActivated = false;
            }
            window.Show();
        }
        catch (Exception ex)
        {
            ProtocolWriter.TryWrite(new { type = "exit", code = 1, error = ex.Message });
            Shutdown(1);
        }
    }
}
