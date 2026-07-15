namespace StickShift.Core;

// Per-frame decision for the WATCH/VERIFY loop.
public enum StepDecision
{
    Wait = 0,     // keep polling
    Matched,      // success — target state observed
    Confirm,      // switch dialog present + policy=confirm -> press confirm
    Cancel,       // switch dialog present + policy=cancel -> press cancel
    DialogOpen,   // switch dialog present + policy=ask -> return DIALOG_OPEN
    Error,        // a known error line appeared
}

// Pure decision layer of src/core/Switch.m — exactly the functions its header marks
// "exposed for tests, without live AX or injection" (the confirm-dialog path that broke
// live 2026-07-13). The full pipeline (runGear / injectAndVerify / awaitStep / revalidate)
// is the OS layer — it needs Attribution, Inject, live pane reads, the interprocess lock,
// and the 150ms frame-age clock — and is deferred to the app increment. These pure pieces
// are the safety-critical brain and port with zero Windows dependency.
public static class Switch
{
    // Last n lines of the pane text — evidence/error needles anchor here so stale
    // scrollback can never satisfy (or fail) a live wait.
    public static string BottomLines(string? txt, int n)
    {
        if (string.IsNullOrEmpty(txt)) return "";
        var bl = txt.Split('\n');
        int bt = bl.Length > n ? bl.Length - n : 0;
        return string.Join("\n", bl[bt..]);
    }

    // Non-overlapping occurrence count; the delivery check requires the typed text's count
    // to INCREASE, so an identical command already in scrollback can't fake delivery.
    public static int OccurrencesOf(string? needle, string? txt)
    {
        if (string.IsNullOrEmpty(needle) || string.IsNullOrEmpty(txt)) return 0;
        int c = 0, i = 0;
        while ((i = txt.IndexOf(needle, i, StringComparison.Ordinal)) >= 0) { c++; i += needle.Length; }
        return c;
    }

    // Is the dialog's extracted target OURS? Claude decorates the target with parenthesized
    // qualifiers — "Opus 4.8 (1M context) (default)" — so exact equality refused our own
    // dialog. Case-insensitive; the expectation must be the whole target or a prefix ending
    // at a token boundary (space or "(") — so "Opus 4.8 (1M context)" matches "Opus 4.8"
    // but "Opus 4.8.1" does not.
    public static bool DialogTargetMatchesExpected(string? target, string? expect)
    {
        if (string.IsNullOrEmpty(target) || string.IsNullOrEmpty(expect)) return false;
        if (string.Equals(target, expect, StringComparison.OrdinalIgnoreCase)) return true;
        if (target.Length > expect.Length
            && string.Equals(target.Substring(0, expect.Length), expect, StringComparison.OrdinalIgnoreCase))
        {
            char next = target[expect.Length];
            return next == ' ' || next == '(';
        }
        return false;
    }

    // Pure no-op test (ALREADY_SET). A null expectEffort means "don't care" (model-only gear).
    public static bool PaneAlreadyAt(PaneState pane, string? expectModel, string? expectEffort)
    {
        // Tolerant match: the status line may carry qualifiers ("Opus 4.8 (1M context)") the plan's
        // display name ("Opus 4.8") omits — match at a token boundary, like the dialog target.
        bool modelMatches = DialogTargetMatchesExpected(pane.ModelText, expectModel);
        // Effort counts as "already there" only from the LIVE footer chip — a stale startup
        // banner ("with high effort") reporting a PAST effort must not no-op a real change.
        bool effortMatches = expectEffort == null || (pane.EffortLive && pane.EffortText == expectEffort);
        return modelMatches && effortMatches;
    }

    // Pure per-frame decision from a classified pane (no side effects). `confirmed` = have
    // we already pressed confirm this run.
    public static StepDecision DecideStep(PlanStep step, PaneState p, bool autoAnswer, DialogPolicy policy, bool confirmed)
    {
        var txt = p.PaneText ?? "";
        // Everything below matches the BOTTOM of the pane only: the full value includes
        // scrollback, where an old "not found", a stale confirmation, or a previous run of
        // this same command would turn history into a current verdict.
        var bottom = BottomLines(txt, 12);
        // Errors first — the agent prints them directly above the composer.
        if (step.ExpectModel != null && bottom.Contains("Model '") && bottom.Contains("' not found")) return StepDecision.Error;
        if (step.ExpectEffort != null && bottom.Contains("Invalid argument")) return StepDecision.Error;
        // Success via classified status line (only when no dialog is open, so the dialog body
        // naming the target model can't be a false positive).
        if (step.ExpectModel != null && !p.SwitchDialogOpen && DialogTargetMatchesExpected(p.ModelText, step.ExpectModel)) return StepDecision.Matched;
        if (step.ExpectEffort != null)
        {
            if (p.EffortLive && p.EffortText == step.ExpectEffort) return StepDecision.Matched; // the LIVE ◉/○ chip
            if (bottom.Contains("Set effort level to " + step.ExpectEffort)) return StepDecision.Matched;
        }
        if (step.ExpectModel == null && step.ExpectEffort == null && step.Text != null
            && BottomLines(txt, 16).Contains(step.Text)) return StepDecision.Matched;
        // The switch-confirm dialog. Only answer OUR dialog: the extracted target must equal
        // this step's expectation — a dialog raised by anything else is left alone.
        if (step.HandlesDialog && p.SwitchDialogOpen && !confirmed)
        {
            var expect = step.ExpectModel ?? step.ExpectEffort;
            bool ours = DialogTargetMatchesExpected(p.DialogTargetDisplay, expect);
            if (!ours) return StepDecision.DialogOpen;
            if (!autoAnswer || policy == DialogPolicy.Ask) return StepDecision.DialogOpen;
            if (policy == DialogPolicy.Cancel) return StepDecision.Cancel;
            return StepDecision.Confirm;
        }
        return StepDecision.Wait;
    }
}
