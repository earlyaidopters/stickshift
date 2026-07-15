using System.Diagnostics;
using System.IO;
using StickShift.Core;
using StickShift.Os;
using CoreSwitch = StickShift.Core.Switch;

// Windows OS-LAYER smoke test — executes the REAL read + inject code (WindowFocus / Injector)
// against a live console window on genuine Windows. Unlike StickShift.Core.Tests (pure classifier
// over fixture strings), this proves the UIA TextPattern read path and SendInput delivery actually
// function on this OS. Runs in CI on windows-latest, where an interactive desktop is available.
//
// Two gates:
//   READ  (hard): spawn a titled console rendering an agent fixture; the port's own
//                 WindowFocus.ReadPaneState must read it via UIA and the classifier must call it a
//                 recognized, idle, empty-composer Claude pane. This is docs/WINDOWS.md step 1,
//                 "the whole project gates on this".
//   INJECT (best-effort, reported): focus the window and SendInput a probe via Injector, then
//                 re-read and check the occurrence-count delta (the engine's own delivery proof).
//                 Reported, not gated, because a headless/service session can block SetForegroundWindow.

const string Title = "SS_SMOKE_PANE";
// Pure-ASCII fixture: "Claude Code v" + "for agents" => agent=Claude; a bare "> " composer line
// => idle + empty composer. No unicode, so the console codepage cannot corrupt the signal.
string fixture =
    "Claude Code v2.1.210\r\n" +
    "Welcome back, CI runner\r\n" +
    "> \r\n" +
    "manual mode on, for agents\r\n";

string fixturePath = Path.Combine(Path.GetTempPath(), "ss_smoke_fixture.txt");
File.WriteAllText(fixturePath, fixture);

int failures = 0;
void Gate(bool cond, string name)
{
    Console.WriteLine($"  [{(cond ? "PASS" : "FAIL")}] {name}");
    if (!cond) failures++;
}

Console.WriteLine("== os-layer smoke (real UIA read + SendInput on Windows) ==");

// Render the fixture in a real console window and leave it at an INTERACTIVE cmd prompt (titled so
// we can find it). cmd at a prompt ECHOES typed characters to its screen buffer, so a delivered
// SendInject keystroke becomes visible to the UIA read — the same echo a live agent composer gives.
// (A sleeping process would swallow the keystroke unseen, hiding real delivery.)
var psi = new ProcessStartInfo
{
    FileName = "cmd.exe",
    Arguments = $"/k title {Title} & type \"{fixturePath}\"",
    UseShellExecute = true,   // give the child its own console window
    WindowStyle = ProcessWindowStyle.Normal,
};
Process? child = Process.Start(psi);
try
{
    // Give the window time to appear and paint its buffer.
    IntPtr hwnd = IntPtr.Zero;
    for (int i = 0; i < 40 && hwnd == IntPtr.Zero; i++)
    {
        Thread.Sleep(500);
        hwnd = WindowFocus.FindWindowByTitle(Title);
    }
    Gate(hwnd != IntPtr.Zero, "spawned console window is findable by title");
    if (hwnd == IntPtr.Zero) { Console.WriteLine("\n{0} FAILED (no window)", failures); return failures == 0 ? 0 : 1; }

    // READ GATE: the port's real UIA read path, then the ported pure classifier.
    PaneState pane = new();
    for (int i = 0; i < 20; i++)
    {
        pane = WindowFocus.ReadPaneState(hwnd);
        if (!string.IsNullOrEmpty(pane.PaneText) && pane.PaneText.Contains("Claude Code v")) break;
        Thread.Sleep(500);
    }
    Console.WriteLine($"  [info] UIA read {pane.PaneText?.Length ?? 0} chars from the console buffer");
    Gate(!string.IsNullOrEmpty(pane.PaneText), "UIA TextPattern read returned buffer text");
    Gate(pane.PaneText?.Contains("Claude Code v") == true, "buffer text contains the rendered fixture");
    Gate(pane.Agent == AgentKind.Claude, "classifier: real UIA read => agent=Claude");
    Gate(pane.Idle, "classifier: real UIA read => idle=YES");
    Gate(pane.InputEmpty, "classifier: real UIA read => composer empty");

    // INJECT (best-effort, reported): drive the real Injector; prove delivery by occurrence delta.
    const string probe = "sszzprobe";
    bool focused = WindowFocus.Focus(hwnd);
    Console.WriteLine($"  [info] Focus() => {focused}; foreground='{WindowFocus.ForegroundWindowTitle()}'");
    if (focused && Injector.CanTypeText(probe))
    {
        int before = CoreSwitch.OccurrencesOf(probe, WindowFocus.ReadPaneState(hwnd).PaneText ?? "");
        WindowFocus.Focus(hwnd);
        Injector.TypeText(probe);
        bool landed = false;
        for (int i = 0; i < 12 && !landed; i++)
        {
            Thread.Sleep(300);
            landed = CoreSwitch.OccurrencesOf(probe, WindowFocus.ReadPaneState(hwnd).PaneText ?? "") > before;
        }
        Console.WriteLine(landed
            ? "  [PASS] INJECT: SendInput probe delivered and read back (real keystroke path works on Windows)"
            : "  [info] INJECT: probe not observed — this runner blocked foreground/keystroke delivery (read path still proven)");
    }
    else
    {
        Console.WriteLine("  [info] INJECT: could not foreground the window on this runner; inject path not exercised (read path still proven)");
    }
}
finally
{
    try { if (child is { HasExited: false }) child.Kill(entireProcessTree: true); } catch { }
    try { File.Delete(fixturePath); } catch { }
}

Console.WriteLine(failures == 0 ? "\nREAD-PATH SMOKE: ALL PASS" : $"\nREAD-PATH SMOKE: {failures} FAILED");
return failures == 0 ? 0 : 1;
