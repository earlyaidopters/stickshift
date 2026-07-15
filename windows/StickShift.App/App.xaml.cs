using System.Windows;

namespace StickShift.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Optional explicit target: --target "<window-title-substring>". If omitted, the window
        // auto-detects the first Claude/Codex session it can read.
        string? target = null;
        for (int i = 0; i < e.Args.Length - 1; i++)
            if (e.Args[i] == "--target") target = e.Args[i + 1];
        new GearboxWindow(target).Show();
    }
}
