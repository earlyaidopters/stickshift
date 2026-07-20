using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;
using StickShift.Core;

namespace StickShift.Os;

// Target acquisition + fail-closed focus for the OS pipeline. This is the PRAGMATIC attribution
// used for the first runnable app: identify the target Windows Terminal window by a title
// substring (Mark's macOS binds pane->process via AX+tty; the full Windows equivalent is the
// WT-UIA-tree + Toolhelp walk of docs/WINDOWS.md step 4 — the safety-critical hardening still
// owed). The load-bearing safety here is the PANE-STATE precheck in SwitchDriver (never inject
// unless the classifier proves the pane idle + composer empty), not the process binding.
public static class WindowFocus
{
    [DllImport("user32.dll")] static extern IntPtr FindWindow(string? cls, string? name);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);

    const uint GW_HWNDNEXT = 2;

    static string TitleOf(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }

    // Diagnostic: the current foreground window's title (where SendInput will actually land).
    public static string ForegroundWindowTitle()
    {
        IntPtr fg = GetForegroundWindow();
        return fg == IntPtr.Zero ? "(none)" : TitleOf(fg);
    }

    // First visible top-level window whose caption contains `titleSubstring` (case-insensitive).
    public static IntPtr FindWindowByTitle(string titleSubstring)
    {
        var want = titleSubstring.ToLowerInvariant();
        IntPtr h = FindWindow(null, null);
        while (h != IntPtr.Zero)
        {
            if (IsWindowVisible(h) && TitleOf(h).ToLowerInvariant().Contains(want)) return h;
            h = GetWindow(h, GW_HWNDNEXT);
        }
        return IntPtr.Zero;
    }

    // Fail-closed focus: attach to the current foreground thread's input queue so SetForegroundWindow
    // is honored, raise the target, then verify it actually became foreground. Returns false if not.
    public static bool Focus(IntPtr target)
    {
        IntPtr foreground = GetForegroundWindow();
        uint foregroundThread = GetWindowThreadProcessId(foreground, out _);
        uint thisThread = GetCurrentThreadId();
        AttachThreadInput(thisThread, foregroundThread, true);
        BringWindowToTop(target);
        SetForegroundWindow(target);
        AttachThreadInput(thisThread, foregroundThread, false);
        Thread.Sleep(180);
        return GetForegroundWindow() == target;
    }

    // Read the Terminal pane text of a specific window handle and classify it (the by-HWND
    // counterpart to UiaPaneReader.ReadFocusedPaneState — used once a target window is chosen).
    // A Windows Terminal window hosts MULTIPLE TextPattern elements (one per tab, plus chrome),
    // so we must not just take the first: iterate them all and PREFER the pane that classifies
    // as a recognized agent. Falls back to the first readable pane if none is an agent.
    public static PaneState ReadPaneState(IntPtr window)
    {
        var empty = new PaneState { HasFocusedWindow = window != IntPtr.Zero };
        if (window == IntPtr.Zero) return empty;
        string title = TitleOf(window);
        empty.WindowTitle = title;
        try
        {
            var el = AutomationElement.FromHandle(window);
            var cond = new PropertyCondition(AutomationElement.IsTextPatternAvailableProperty, true);
            PaneState? firstReadable = null;
            foreach (AutomationElement pane in el.FindAll(TreeScope.Descendants, cond))
            {
                string text;
                try { var fullText = ((TextPattern)pane.GetCurrentPattern(TextPattern.Pattern)).DocumentRange.GetText(-1) ?? ""; text = fullText.Length > 200_000 ? fullText[^200_000..] : fullText; }
                catch { continue; }
                if (string.IsNullOrEmpty(text)) continue;
                var candidate = new PaneState { HasFocusedWindow = true, WindowTitle = title, PaneText = text };
                PaneClassifier.ClassifyText(text, candidate);
                if (candidate.Agent != AgentKind.Unknown) return candidate;   // the agent pane — use it
                firstReadable ??= candidate;
            }
            return firstReadable ?? empty;
        }
        catch { return empty; } // fail closed
    }

    // Give the on-screen agent pane KEYBOARD FOCUS within the window (UIA SetFocus on the
    // TermControl). Being the foreground window is not enough — SendInput routes to the control
    // with keyboard focus, and a console-launched process often leaves the pane unfocused. Returns
    // the classified pane + whether an on-screen agent element was found and focused.
    public static (PaneState pane, bool focused) FocusActiveAgentPane(IntPtr window)
    {
        var empty = new PaneState { HasFocusedWindow = window != IntPtr.Zero, WindowTitle = window == IntPtr.Zero ? null : TitleOf(window) };
        if (window == IntPtr.Zero) return (empty, false);
        try
        {
            var el = AutomationElement.FromHandle(window);
            var cond = new PropertyCondition(AutomationElement.IsTextPatternAvailableProperty, true);
            AutomationElement? agentEl = null, fallbackEl = null; PaneState? agentSt = null, fallbackSt = null;
            foreach (AutomationElement pane in el.FindAll(TreeScope.Descendants, cond))
            {
                string text;
                try { var fullText = ((TextPattern)pane.GetCurrentPattern(TextPattern.Pattern)).DocumentRange.GetText(-1) ?? ""; text = fullText.Length > 200_000 ? fullText[^200_000..] : fullText; }
                catch { continue; }
                if (string.IsNullOrEmpty(text)) continue;
                var st = new PaneState { HasFocusedWindow = true, WindowTitle = empty.WindowTitle, PaneText = text };
                PaneClassifier.ClassifyText(text, st);
                bool onScreen = false;
                try { onScreen = !(bool)pane.GetCurrentPropertyValue(AutomationElement.IsOffscreenProperty); } catch { }
                if (st.Agent != AgentKind.Unknown && onScreen) { agentEl = pane; agentSt = st; break; }
                if (st.Agent != AgentKind.Unknown) { agentEl ??= pane; agentSt ??= st; }
                fallbackEl ??= pane; fallbackSt ??= st;
            }
            var chosenEl = agentEl ?? fallbackEl;
            var chosenSt = agentSt ?? fallbackSt ?? empty;
            if (chosenEl == null) return (empty, false);
            bool focused = false;
            try { chosenEl.SetFocus(); focused = true; Thread.Sleep(120); } catch { }
            return (chosenSt, focused);
        }
        catch { return (empty, false); }
    }

    // The ACTIVE agent pane of a window: among its TextPattern panes, prefer the one that both
    // classifies as an agent AND is on-screen. Windows Terminal keeps INACTIVE tabs off-screen, so
    // the on-screen agent pane is the active tab — exactly where SendInput lands. Falls back to any
    // agent pane, then any readable pane. This is the read that guarantees read-pane == inject-pane.
    public static PaneState ReadActiveAgentPane(IntPtr window)
    {
        var empty = new PaneState { HasFocusedWindow = window != IntPtr.Zero };
        if (window == IntPtr.Zero) return empty;
        string title = TitleOf(window);
        empty.WindowTitle = title;
        try
        {
            var el = AutomationElement.FromHandle(window);
            var cond = new PropertyCondition(AutomationElement.IsTextPatternAvailableProperty, true);
            PaneState? onScreenAny = null, anyAgent = null, firstReadable = null;
            foreach (AutomationElement pane in el.FindAll(TreeScope.Descendants, cond))
            {
                string text;
                try { var fullText = ((TextPattern)pane.GetCurrentPattern(TextPattern.Pattern)).DocumentRange.GetText(-1) ?? ""; text = fullText.Length > 200_000 ? fullText[^200_000..] : fullText; }
                catch { continue; }
                if (string.IsNullOrEmpty(text)) continue;
                var st = new PaneState { HasFocusedWindow = true, WindowTitle = title, PaneText = text };
                PaneClassifier.ClassifyText(text, st);
                bool onScreen = false;
                try { onScreen = !(bool)pane.GetCurrentPropertyValue(AutomationElement.IsOffscreenProperty); } catch { }
                if (st.Agent != AgentKind.Unknown && onScreen) return st;   // the ACTIVE agent pane
                if (onScreen) onScreenAny ??= st;                          // on-screen, not (yet) an agent
                if (st.Agent != AgentKind.Unknown) anyAgent ??= st;
                firstReadable ??= st;
            }
            // Prefer an ON-SCREEN pane (even a non-agent one -> caller refuses NO_AGENT) over an
            // OFF-SCREEN agent: SendInput reaches only the active tab, so acting on an off-screen
            // agent pane would type into the wrong place. The off-screen agent is a read-only last
            // resort (dry-run/diagnostics), never the on-screen commit target.
            return onScreenAny ?? anyAgent ?? firstReadable ?? empty;
        }
        catch { return empty; }
    }
}
