using System;
using System.Windows;

namespace TerminalHost;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        try
        {
            var options = TerminalHost.MainWindow.ParseArguments(e.Args);
            var window = new TerminalHost.MainWindow(options);
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

