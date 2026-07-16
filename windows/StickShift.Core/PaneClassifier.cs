using System.Text.RegularExpressions;

namespace StickShift.Core;

// Faithful C# port of src/core/AXState.m's PURE classification logic (classifyText,
// isInputEmpty, codexPickerRowFor, plausibleCwd + the display-string tables). The macOS
// AX-reading methods (readFocusedPaneForTerminal, frontmostPid, keyboardFocusPid) are the
// OS layer and are NOT here — on Windows they become UI Automation (docs/WINDOWS.md), which
// produces the same `paneText` string this classifier consumes. Success criterion: the
// classifier reproduces the verdicts in tests/core_test.m on the same fixtures.
public static class PaneClassifier
{
    // Known display strings (verbatim from AXState.m).
    static readonly string[] ClaudeModels =
    {
        "Opus 4.8 (1M context) (default)", "Opus 4.8 (1M context)", "Opus 4.8",
        "Fable 5", "Sonnet 5", "Haiku 4.5"
    };

    static readonly string[] CodexPlaceholders =
    {
        "Explain this codebase", "Summarize recent commits", "Implement {feature}",
        "Find and fix a bug in @filename", "Write tests for @filename",
        "Improve documentation in @filename", "Run /review on my current changes",
        "Use /skills to list available skills",
        "Check recently modified functions for compatibility",
        "How many files have been modified?", "Will this algorithm scale well?",
        "Ready. What would you like to work on?", "Ask anything"
    };

    static readonly string[] ClaudePlaceholders =
    {
        "Press up to edit queued messages", "Try \"", "Ask Claude",
        "Update your working directory"
    };

    static readonly string[] EffortWords =
    {
        "low", "medium", "high", "xhigh", "max", "ultracode", "ultra", "extra high", "auto"
    };

    const string SpinnerGlyphs = "✻✽✢✳✶✺⚹✷✵"; // ✻✽✢✳✶✺⚹✷✵

    static string Trim(string s) => s.Trim();

    public static void ClassifyText(string? text, PaneState st)
    {
        if (string.IsNullOrEmpty(text)) return;
        var lines = text.Split('\n');
        var lower = text.ToLowerInvariant();

        // --- agent detection ---
        bool looksClaude = (text.Contains("📂") && text.Contains(" · ")) ||
                           text.Contains("bypass permissions") ||
                           text.Contains("for agents") ||
                           lower.Contains("claude code v") ||
                           (text.Contains("5h:") && text.Contains("7d:"));
        bool looksCodex = text.Contains("OpenAI Codex") ||
                          text.Contains("/model to change") ||
                          (lower.Contains("gpt-") &&
                           (text.Contains(" · /") || text.Contains(" ~/")));
        if (looksClaude && !looksCodex) st.Agent = AgentKind.Claude;
        else if (looksCodex && !looksClaude) st.Agent = AgentKind.Codex;
        else if (looksClaude && looksCodex) st.Agent = AgentKind.Claude; // claude chrome is more specific
        else st.Agent = AgentKind.Unknown;

        // --- busy / dialog (bottom-anchored: only trust the last 16 lines so scrollback
        // that quotes these markers does not false-trigger) ---
        int btail = lines.Length > 16 ? lines.Length - 16 : 0;
        var btmLines = lines[btail..];

        var btm = string.Join("\n", btmLines);
        bool busy = btm.Contains("esc to interrupt") || btm.Contains("• Working");
        if (!busy)
        {
            foreach (var ln in btmLines)
            {
                var tr = Trim(ln);
                if (tr.Length > 0 && SpinnerGlyphs.IndexOf(tr[0]) >= 0 &&
                    tr.Contains('(') && tr.Contains('s')) { busy = true; break; }
            }
        }
        st.Busy = busy;

        // Dialog detection anchored to the rendered option LINES at the bottom.
        bool dTitle = false, dYes = false, dNo = false;
        foreach (var raw in btmLines)
        {
            var s = Trim(raw);
            int caret = s.IndexOf('❯');
            if (s.StartsWith('❯')) s = Trim(s[(caret + 1)..]);
            if (s.StartsWith("1.")) s = Trim(s[2..]);
            else if (s.StartsWith("2.")) s = Trim(s[2..]);
            if (s == "Switch model?" || s == "Change effort level?") dTitle = true;
            else if (s.StartsWith("Yes, switch to"))
            {
                dYes = true;
                st.DialogTargetDisplay = Trim(s["Yes, switch to".Length..]);
            }
            else if (s == "No, go back") dNo = true;
        }
        st.SwitchDialogOpen = dTitle && dYes && dNo;
        // The confirm dialogs are Claude-only chrome and hide the status line, so a
        // dialog-only pane would classify Unknown — pin it to Claude.
        if (st.Agent == AgentKind.Unknown && st.SwitchDialogOpen) st.Agent = AgentKind.Claude;

        // --- model + effort ---
        if (st.Agent == AgentKind.Claude)
        {
            foreach (var ln in lines)
            {
                int f = ln.IndexOf("📂 ", StringComparison.Ordinal);
                if (f < 0) continue;
                var rest = ln[(f + "📂 ".Length)..];
                var parts = rest.Split('·');
                if (parts.Length >= 1) st.CwdHint = Trim(parts[0]);
                if (parts.Length >= 2)
                {
                    var mseg = Trim(parts[1]);
                    foreach (var stopper in new[] { "▰", "▱", "  ", "/rc" })
                    {
                        int sr = mseg.IndexOf(stopper, StringComparison.Ordinal);
                        if (sr >= 0) mseg = mseg[..sr];
                    }
                    mseg = Trim(mseg);
                    foreach (var m in ClaudeModels)
                        if (mseg == m) { st.ModelText = m; break; }
                    if (st.ModelText == null && mseg.Length > 0) st.ModelText = mseg;
                }
                break;
            }
            // The "<effort> · /effort" chip is LIVE state — but only when it sits in the bottom
            // footer region; old footers can be stranded higher in scrollback by reflows.
            var chipRegion = Switch.BottomLines(text, 8);
            foreach (var e in EffortWords)
            {
                var needle = $" {e} · /effort";
                if (chipRegion.Contains(needle)) { st.EffortText = e; st.EffortLive = true; break; }
            }
            // Windows Claude Code renders no "📂 cwd · Model · /effort" footer. Instead:
            //   - idle status line:  "<Model> · ctx …"
            //   - startup banner:    "<Model> with <effort> effort · Claude Max"
            //   - settings line:     "Using <Model> (from .claude\settings.json) · /model"
            // Parse the model/effort from those when the macOS footer wasn't present.
            if (st.ModelText == null)
            {
                // The LIVE model is the bottom-most idle status footer "<Model> · ctx …". Stale
                // startup banners ("<Model> with <effort> effort · Claude Max") and old resized
                // footers litter the scrollback naming PAST models, so scan UP from the bottom and
                // read the model off the LAST "· ctx" line. A banner "with"/"Using" line must NEVER
                // outrank a live footer — that misread reported a resized-away model as current
                // (e.g. a stale "Opus 4.8 (1M context) with hi…" beating the live "Sonnet 5 · ctx").
                for (int i = lines.Length - 1; i >= 0 && st.ModelText == null; i--)
                {
                    int c = lines[i].IndexOf(" · ctx", StringComparison.Ordinal);
                    if (c < 0) continue;
                    var head = Trim(lines[i][..c]);
                    foreach (var m in ClaudeModels)
                        if (head == m || head.StartsWith(m + " ", StringComparison.Ordinal))
                        { st.ModelText = head; break; }   // keep full head; tolerant match handles "(1M context)"
                }
                // Fallback ONLY when no live "· ctx" footer exists yet (e.g. the first startup frames).
                if (st.ModelText == null)
                    foreach (var m in ClaudeModels)
                        if (text.Contains($"{m} with ", StringComparison.Ordinal) ||
                            text.Contains($"Using {m} ", StringComparison.Ordinal))
                        { st.ModelText = m; break; }
            }
            if (st.EffortText == null)
            {
                var me = Regex.Match(text, @"\bwith (\w+) effort\b");
                if (me.Success)
                {
                    var e = me.Groups[1].Value.ToLowerInvariant();
                    if (Array.IndexOf(EffortWords, e) >= 0) st.EffortText = e;
                }
            }
        }
        else if (st.Agent == AgentKind.Codex)
        {
            var re = new Regex(
                @"(gpt-[A-Za-z0-9._-]+)\s+(extra high|low|medium|high|xhigh|max|ultra)\s+(?:·\s+)?((?:/|~/)[^\n]+)");
            foreach (Match mm in re.Matches(text))
            {
                st.ModelText = mm.Groups[1].Value;
                st.EffortText = mm.Groups[2].Value;
                var cwd = PlausibleCwd(mm.Groups[3].Value);
                if (cwd != null) st.CwdHint = cwd;
            }
            if (string.IsNullOrEmpty(st.CwdHint))
            {
                var dre = new Regex(@"directory:\s+((?:/|~/)[^\n]+)");
                foreach (Match dm in dre.Matches(text))
                {
                    var cwd = PlausibleCwd(dm.Groups[1].Value);
                    if (cwd != null) st.CwdHint = cwd;
                }
            }
        }

        // --- input empty / draft present ---
        st.InputEmpty = IsInputEmpty(lines, st.Agent);

        // --- idle: positive prompt, not busy, no dialog ---
        bool promptPresent = (st.Agent == AgentKind.Claude && HasClaudePrompt(lines)) ||
                             (st.Agent == AgentKind.Codex && text.Contains('›'));
        st.Idle = promptPresent && !st.Busy && !st.SwitchDialogOpen && st.Agent != AgentKind.Unknown;
    }

    // A Claude composer prompt in the bottom region: macOS renders "❯"; Windows Claude Code
    // renders "> " (a line that is exactly ">" or starts with "> "). A shell prompt like
    // "PS C:\...>" ENDS with ">" and is not matched; the Claude composer STARTS with it.
    static bool HasClaudePrompt(string[] lines)
    {
        int start = Math.Max(0, lines.Length - 20);
        for (int i = lines.Length - 1; i >= start; i--)
        {
            var ln = Trim(lines[i]);
            if (ln.StartsWith('❯') || ln == ">" || ln.StartsWith("> ")) return true;
        }
        return false;
    }

    // Fail closed: unknown -> false (draft present).
    static bool IsInputEmpty(string[] lines, AgentKind agent)
    {
        if (agent == AgentKind.Claude)
        {
            for (int i = lines.Length - 1; i >= 0; i--)
            {
                var ln = Trim(lines[i]);
                // macOS composer starts with "❯"; Windows Claude Code composer is "> " (a line
                // that is exactly ">" or starts with "> "). A shell prompt ("PS C:\...>") ends
                // with ">" and is not matched — the composer starts with it.
                bool mac = ln.StartsWith('❯');
                bool win = ln == ">" || ln.StartsWith("> ");
                if (mac || win)
                {
                    int markerLen = mac ? (ln.IndexOf('❯') + 1) : 1;
                    var rest = Trim(ln[markerLen..]);
                    if (rest.Length == 0) return true;                              // empty composer
                    if (rest.StartsWith("1.") || rest.StartsWith("2.")) continue;   // dialog option
                    // EXACT match only (like the Codex branch): a StartsWith would classify a real
                    // draft that merely BEGINS with a placeholder ("Ask Claude about the race…") as
                    // empty and type over it. An empty composer is already caught by rest.Length==0.
                    foreach (var ph in ClaudePlaceholders) if (rest == ph) return true;
                    return false;                                                   // draft present
                }
            }
            return false;
        }
        if (agent == AgentKind.Codex)
        {
            for (int i = lines.Length - 1; i >= 0; i--)
            {
                var ln = Trim(lines[i]);
                if (ln.StartsWith('›'))
                {
                    var rest = Trim(ln[(ln.IndexOf('›') + 1)..]);
                    if (rest.Length == 0) return true;
                    foreach (var ph in CodexPlaceholders) if (rest == ph) return true;
                    return false;
                }
            }
            return false;
        }
        return false;
    }

    // A footer capture qualifies as a cwd only if it reads like a directory.
    static string? PlausibleCwd(string capture)
    {
        var cwd = Trim(capture);
        if (cwd.Length == 0) return null;
        if (cwd.Contains(" | ") || cwd.Contains('…')) return null;
        if (cwd.StartsWith("~/"))
            cwd = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + cwd[1..];
        return cwd;
    }

    // 1-based row of a Codex picker option matching `label` (case-insensitive full-token,
    // after the "N. " marker). 0 if absent. Port of codexPickerRowFor.
    public static int CodexPickerRowFor(string? label, string? text)
    {
        if (string.IsNullOrEmpty(label) || string.IsNullOrEmpty(text)) return 0;
        var want = label.ToLowerInvariant();
        foreach (var raw in text.Split('\n'))
        {
            var ln = Trim(raw);
            if (ln.StartsWith('›')) ln = Trim(ln[(ln.IndexOf('›') + 1)..]);
            int dot = ln.IndexOf(". ", StringComparison.Ordinal);
            if (dot <= 0 || dot > 2) continue;
            if (!int.TryParse(ln[..dot], out int n) || n <= 0) continue;
            var restp = ln[(dot + 2)..].ToLowerInvariant();
            if (restp.StartsWith(want))
            {
                if (restp.Length == want.Length) return n;
                char next = restp[want.Length];
                if (next is ' ' or '\t' or '(') return n;
            }
        }
        return 0;
    }
}
