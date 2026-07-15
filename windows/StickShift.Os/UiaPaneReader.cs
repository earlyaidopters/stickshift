using System.Windows.Automation;
using StickShift.Core;

namespace StickShift.Os;

// Windows OS-layer READ PATH — the port of macOS AXState's pane read (docs/WINDOWS.md step 1,
// "the whole project gates on this"). Reads a Windows Terminal pane's buffer via UI Automation
// TextPattern (WM_GETTEXT cannot read Terminal's DirectWrite surface) and feeds it to the ported
// PURE classifier in StickShift.Core. Passive: no focus change, no injection.
//
// Recipe borrowed from the validated POC (stickshift-windows: spike1-read-terminal.ps1 +
// UiaTextReader.cs). This layer is compile-verified and correctly wired to Core; the live
// end-to-end (does WT's UIA text drive the classifier on a real focused pane) is a hand-test
// with a running Windows Terminal — the first thing to try when back at the machine.
public static class UiaPaneReader
{
    const string TerminalWindowClass = "CASCADIA_HOSTING_WINDOW_CLASS";

    // One readable terminal pane: its buffer text and the PID that owns its host window.
    public sealed class TerminalPane
    {
        public int HostProcessId { get; init; }
        public string WindowTitle { get; init; } = "";
        public string PaneName { get; init; } = "";
        public string BufferText { get; init; } = "";
    }

    // All readable panes across every Windows Terminal top-level window.
    public static IReadOnlyList<TerminalPane> ReadTerminalPanes(int maxCharsPerPane = 100_000)
    {
        var result = new List<TerminalPane>();
        var root = AutomationElement.RootElement;
        var windows = root.FindAll(TreeScope.Children,
            new PropertyCondition(AutomationElement.ClassNameProperty, TerminalWindowClass));
        foreach (AutomationElement window in windows)
        {
            int pid = window.Current.ProcessId;
            string title = window.Current.Name ?? "";
            var panes = window.FindAll(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.IsTextPatternAvailableProperty, true));
            foreach (AutomationElement pane in panes)
            {
                string text;
                try
                {
                    var tp = (TextPattern)pane.GetCurrentPattern(TextPattern.Pattern);
                    text = tp.DocumentRange.GetText(maxCharsPerPane) ?? "";
                }
                catch { continue; } // pane gone / access denied — fail closed (no text, no action)
                result.Add(new TerminalPane
                {
                    HostProcessId = pid,
                    WindowTitle = title,
                    PaneName = pane.Current.Name ?? "",
                    BufferText = text,
                });
            }
        }
        return result;
    }

    // The FOCUSED Windows Terminal pane, classified into a PaneState — the port of
    // AXState.readFocusedPaneForTerminal. Fail-closed: an unreadable/absent focus returns an
    // empty PaneState (HasFocusedWindow=false), so the safety preconditions refuse.
    public static PaneState ReadFocusedPaneState()
    {
        var st = new PaneState();
        AutomationElement? focused;
        try { focused = AutomationElement.FocusedElement; } catch { return st; }
        if (focused is null) return st;

        // Walk up from the focused element to its top-level Terminal window.
        var walker = TreeWalker.ControlViewWalker;
        AutomationElement? node = focused, window = null;
        try
        {
            while (node is not null)
            {
                if (node.Current.ControlType == ControlType.Window &&
                    node.Current.ClassName == TerminalWindowClass) { window = node; break; }
                node = walker.GetParent(node);
            }
        }
        catch { return st; }
        if (window is null) return st;

        st.HasFocusedWindow = true;
        try { st.WindowTitle = window.Current.Name ?? ""; } catch { /* leave null */ }

        // Prefer the focused element's own TextPattern; else the first TextPattern pane in the window.
        string? text = TryReadText(focused) ?? TryReadFirstPaneText(window);
        if (!string.IsNullOrEmpty(text))
        {
            st.PaneText = text;
            PaneClassifier.ClassifyText(text, st);   // the ported pure classifier decides idle/busy/model/effort
        }
        return st;
    }

    static string? TryReadText(AutomationElement el)
    {
        try
        {
            if ((bool)el.GetCurrentPropertyValue(AutomationElement.IsTextPatternAvailableProperty))
            {
                var tp = (TextPattern)el.GetCurrentPattern(TextPattern.Pattern);
                return tp.DocumentRange.GetText(100_000);
            }
        }
        catch { /* fall through */ }
        return null;
    }

    static string? TryReadFirstPaneText(AutomationElement window)
    {
        try
        {
            var pane = window.FindFirst(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.IsTextPatternAvailableProperty, true));
            return pane is null ? null : TryReadText(pane);
        }
        catch { return null; }
    }
}
