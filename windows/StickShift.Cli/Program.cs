using StickShift.Core;
using StickShift.Os;

// StickShift CLI — the runnable Windows gearbox (headless). Port of src/cli/main.m.
//
//   stickshift <gear> --target <title-substring> [--commit]
//   stickshift --list          # list readable Windows Terminal panes + their classification
//
// Gears: 1 2 3 4 5 R ULTRA (Config gear table). Default is a DRY RUN (prints the plan); pass
// --commit to actually perform the shift. Targeting is by a substring of the Windows Terminal
// window title — give the target Claude Code / Codex session a distinctive title (Claude Code's
// /rename, or the auto-title) so it resolves uniquely.
internal static class Cli
{
    [STAThread]
    static int Main(string[] args)
    {
        Console.OutputEncoding = System.Text.Encoding.UTF8;

        if (args.Length == 0 || args.Contains("-h") || args.Contains("--help"))
        {
            Console.WriteLine("stickshift <gear> --target <title-substring> [--commit]");
            Console.WriteLine("stickshift --list");
            Console.WriteLine($"gears: {string.Join(' ', Config.AllGears)}   (default = dry run; --commit performs the shift)");
            return args.Length == 0 ? 1 : 0;
        }

        if (args.Contains("--list"))
        {
            var panes = UiaPaneReader.ReadTerminalPanes();
            if (panes.Count == 0) { Console.WriteLine("(no readable Windows Terminal panes)"); return 0; }
            foreach (var pane in panes)
            {
                var ps = new PaneState();
                PaneClassifier.ClassifyText(pane.BufferText, ps);
                string extra = ps.Agent != AgentKind.Unknown ? $" model={ps.ModelText ?? "?"} idle={ps.Idle}" : "";
                Console.WriteLine($"  [{ps.Agent}] '{pane.WindowTitle}'{extra}");
            }
            return 0;
        }

        // Diagnostic: dump the target's active-pane classification + the bottom lines EXACTLY as the
        // classifier sees them (each bracketed so leading/trailing space + box glyphs are visible).
        // Read-only; used to debug false DRAFT_PRESENT / model misreads against real terminal state.
        if (args.Contains("--dump"))
        {
            string? t = ArgValue(args, "--target");
            if (string.IsNullOrEmpty(t)) { Console.WriteLine("error: --dump needs --target"); return 2; }
            var hwnd = WindowFocus.FindWindowByTitle(t);
            if (hwnd == IntPtr.Zero) { Console.WriteLine($"no window titled *{t}*"); return 1; }
            var st = WindowFocus.ReadActiveAgentPane(hwnd);
            Console.WriteLine($"agent={st.Agent} idle={st.Idle} inputEmpty={st.InputEmpty} busy={st.Busy} dialog={st.SwitchDialogOpen} model={st.ModelText ?? "?"} effort={st.EffortText ?? "?"}");
            var allLines = (st.PaneText ?? "").Replace("\r", "").Split('\n');
            int from = Math.Max(0, allLines.Length - 24);
            Console.WriteLine($"--- bottom {allLines.Length - from} of {allLines.Length} lines ---");
            for (int i = from; i < allLines.Length; i++)
                Console.WriteLine($"[{allLines[i]}]");
            return 0;
        }

        // Explicit draft-clear: presses Escape in the target composer (Claude Code: Esc clears the
        // input line) and verifies by re-read. Operator-invoked only — the shift itself stays
        // fail-closed on DRAFT_PRESENT; this is the deliberate way OUT of that refusal when the
        // draft is stray (e.g. a command typed by an earlier run whose Return never landed).
        if (args.Contains("--clear-draft"))
        {
            string? t = ArgValue(args, "--target");
            if (string.IsNullOrEmpty(t)) { Console.WriteLine("error: --clear-draft needs --target"); return 2; }
            var hwnd = WindowFocus.FindWindowByTitle(t);
            if (hwnd == IntPtr.Zero) { Console.WriteLine($"no window titled *{t}*"); return 1; }
            var st = WindowFocus.ReadActiveAgentPane(hwnd);
            if (st.Agent == AgentKind.Unknown) { Console.WriteLine("NO_AGENT — active pane is not a recognized agent"); return 1; }
            if (st.Busy) { Console.WriteLine("BUSY — refusing to press Escape while the agent is running (it would interrupt)"); return 1; }
            if (st.InputEmpty) { Console.WriteLine("ALREADY_EMPTY — composer has no draft"); return 0; }
            // Serialize with the SAME interprocess lock the shift uses, so a clear-draft can't
            // interleave keystrokes with a concurrent shift (CLI + GUI, or two pulls) into the same
            // pane. Fail-closed if we can't take it quickly. (Matches SwitchDriver's StickShiftInjectionLock.)
            using var injectionGate = new Mutex(false, "StickShiftInjectionLock");
            bool lockAcquired;
            try { lockAcquired = injectionGate.WaitOne(TimeSpan.FromMilliseconds(600)); }
            catch (AbandonedMutexException) { lockAcquired = true; }   // a prior holder died mid-inject; inherit
            if (!lockAcquired) { Console.WriteLine("LOCKED — another shift/clear is in progress — try again"); return 1; }
            try
            {
                if (!WindowFocus.Focus(hwnd)) { Console.WriteLine("NO_FOCUS — could not bring the target to foreground"); return 1; }
                // Backspace the draft away, one key per character (+ margin — extra backspaces on an
                // empty composer are harmless). NOT Escape: typing "/…" opens the slash-autocomplete
                // popup, and Esc closes that popup instead of clearing the text (observed live).
                int draftLen = 0;
                foreach (var raw in (st.PaneText ?? "").Replace("\r", "").Split('\n'))
                {
                    var ln = raw.TrimEnd();
                    var lt = ln.TrimStart();
                    if (lt == ">" || lt.StartsWith("> ")) draftLen = Math.Max(draftLen, lt.Length - 1);
                }
                int presses = Math.Min(draftLen + 8, 300);
                Thread.Sleep(150);
                // Re-assert foreground BEFORE every Backspace and ABORT if it isn't the target. A
                // focus drop mid-loop must NOT blind-fire destructive Backspaces into whatever window
                // now owns focus — the same fail-closed rule SwitchDriver applies to every keystroke,
                // and it matters most here because Backspace is destructive (was: Focus() called but
                // its bool ignored, so up to 300 backspaces could land in the wrong window).
                for (int k = 0; k < presses; k++)
                {
                    if (!WindowFocus.Focus(hwnd))
                    {
                        Console.WriteLine($"NO_FOCUS — target lost foreground after {k} backspaces; aborted before typing into the wrong window");
                        return 1;
                    }
                    Injector.PressBackspace();
                    Thread.Sleep(15);
                }
                Thread.Sleep(400);
                var after = WindowFocus.ReadActiveAgentPane(hwnd);
                Console.WriteLine(after.InputEmpty
                    ? $"CLEARED — composer verified empty ({presses} backspaces)"
                    : "STILL_PRESENT — composer not empty after backspacing");
                return after.InputEmpty ? 0 : 1;
            }
            finally { injectionGate.ReleaseMutex(); }
        }

        string gear = args[0];
        string? target = ArgValue(args, "--target");
        bool commit = args.Contains("--commit");
        if (string.IsNullOrEmpty(target))
        {
            Console.WriteLine("error: --target <title-substring> is required (the Windows Terminal window running the agent).");
            return 2;
        }
        if (!Config.AllGears.Contains(gear.ToUpperInvariant()) && !Config.AllGears.Contains(gear))
        {
            Console.WriteLine($"error: unknown gear '{gear}'. gears: {string.Join(' ', Config.AllGears)}");
            return 2;
        }

        var cfg = new Config();
        bool debug = args.Contains("--debug") || args.Contains("-d");
        Action<string>? log = debug ? Console.WriteLine : null;
        ShiftOutcome outcome = SwitchDriver.Shift(target, gear, cfg, commit, log);

        Console.WriteLine(outcome);
        if (outcome.PlanSummary != null && !commit)
            Console.WriteLine($"  plan: {outcome.PlanSummary}   (add --commit to apply)");

        // Exit code: 0 on success/dry-run/already-set; non-zero on a refusal or failure.
        return outcome.Reason is "OK" or "CHANGED" or "ALREADY_SET" ? 0 : 1;
    }

    static string? ArgValue(string[] args, string flag)
    {
        int i = Array.IndexOf(args, flag);
        return (i >= 0 && i + 1 < args.Length) ? args[i + 1] : null;
    }
}
