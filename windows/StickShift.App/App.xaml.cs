using System.Windows;

namespace StickShift.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Optional explicit target: --target "<window-title-substring>". If omitted (or given with no
        // value), the window auto-detects the first Claude/Codex session it can read. (The old loop
        // bound `< Length - 1` silently dropped --target when it was the final argument.)
        string? explicitTarget = null;
        string[] arguments = e.Args;
        for (int index = 0; index < arguments.Length; index++)
            if (arguments[index] == "--target" && index + 1 < arguments.Length)
                explicitTarget = arguments[index + 1];
        new GearboxWindow(explicitTarget).Show();
    }
}
