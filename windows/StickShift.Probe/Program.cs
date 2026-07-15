using StickShift.Core;
using StickShift.Os;

// Read-path probe — docs/WINDOWS.md step 1's success criterion, made runnable:
// "grab the focused Windows Terminal pane's text via UIA and print it; feed it to the
// classifier." Focus a Windows Terminal pane running Claude Code / Codex, then run this exe.
// It proves (or disproves) that WT's UIA text is high-enough fidelity to drive the classifier.
internal static class Probe
{
    [STAThread]
    static int Main(string[] args)
    {
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        // The probe reads the FOCUSED element at read-time — so launching it from a shell
        // would read that shell. Count down first (default 4s) so you can Alt-Tab to the
        // Windows Terminal pane running Claude Code / Codex you actually want to classify.
        int delaySec = (args.Length > 0 && int.TryParse(args[0], out int d) && d >= 0) ? d : 4;
        Console.WriteLine("StickShift read-path probe.");
        Console.WriteLine("Focus the Windows Terminal pane to read (e.g. one running Claude Code / Codex).");
        for (int i = delaySec; i > 0; i--)
        {
            Console.Write($"\r  reading the focused pane in {i}s ...   ");
            System.Threading.Thread.Sleep(1000);
        }
        Console.WriteLine("\r  reading now.                          \n");

        PaneState st = UiaPaneReader.ReadFocusedPaneState();
        if (!st.HasFocusedWindow)
        {
            Console.WriteLine("NO focused Windows Terminal window found up the focus chain");
            Console.WriteLine("(CASCADIA_HOSTING_WINDOW_CLASS). Focus a WT pane and re-run.");
            Console.WriteLine("=> read path returned an empty PaneState — fail-closed, which is correct.");
            return 1;
        }

        Console.WriteLine($"window title : {st.WindowTitle}");
        Console.WriteLine($"pane text    : {st.PaneText?.Length ?? 0} chars read");
        Console.WriteLine($"agent        : {st.Agent}");
        Console.WriteLine($"model        : {st.ModelText ?? "(none)"}");
        Console.WriteLine($"effort       : {st.EffortText ?? "(none)"}");
        Console.WriteLine($"cwd hint     : {st.CwdHint ?? "(none)"}");
        Console.WriteLine($"idle         : {st.Idle}");
        Console.WriteLine($"busy         : {st.Busy}");
        Console.WriteLine($"inputEmpty   : {st.InputEmpty}");
        Console.WriteLine($"dialog open  : {st.SwitchDialogOpen}");
        Console.WriteLine("\n--- last 12 non-empty lines the classifier saw ---");
        Console.WriteLine(Switch.BottomLines(st.PaneText, 12));

        // Also enumerate EVERY readable Windows Terminal pane and classify each — so a
        // Claude Code / Codex pane is found wherever it is, with no focus-timing needed.
        Console.WriteLine("\n=== all Windows Terminal panes (classified) ===");
        var panes = UiaPaneReader.ReadTerminalPanes();
        if (panes.Count == 0)
            Console.WriteLine("(no Windows Terminal panes with readable text found)");
        foreach (var pane in panes)
        {
            var ps = new PaneState();
            PaneClassifier.ClassifyText(pane.BufferText, ps);
            string extra = ps.Agent != AgentKind.Unknown
                ? $"  model={ps.ModelText ?? "?"} effort={ps.EffortText ?? "?"} idle={ps.Idle} inputEmpty={ps.InputEmpty}"
                : "";
            Console.WriteLine($"  [{ps.Agent}] '{pane.WindowTitle}' / '{pane.PaneName}' — {pane.BufferText.Length} chars{extra}");
            // For a detected agent pane, dump the tail so its Windows status-line / prompt
            // format can be captured as a fixture and the parsing markers widened.
            if (ps.Agent != AgentKind.Unknown && (ps.ModelText is null || !ps.Idle))
            {
                Console.WriteLine("    --- tail (24 lines) — paste this to tune Windows model/idle parsing ---");
                foreach (var ln in Switch.BottomLines(pane.BufferText, 24).Split('\n'))
                    Console.WriteLine("    | " + ln);
                Console.WriteLine("    --- end tail ---");
            }
        }
        Console.WriteLine("\n(if a Claude Code / Codex pane shows [Unknown], paste its text and I'll tune the");
        Console.WriteLine(" Windows agent-detection markers — the classifier is 22/22 on captured macOS panes.)");

        // Success criterion (Mark): the tail shows the composer line + status footer with
        // enough fidelity for the classifier. If agent==Unknown or model is (none) on a real
        // Claude/Codex pane, that is the read-fidelity gap to investigate, NOT a classifier bug
        // (the classifier is proven at 22/22 on captured fixtures).
        return 0;
    }
}
