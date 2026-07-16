using StickShift.Core;

namespace StickShift.Os;

public sealed class ShiftOutcome
{
    public string Reason = "";
    public string Stage = "";
    public string Detail = "";
    public bool Committed;
    public string? PlanSummary;
    public override string ToString() =>
        Reason + (Stage.Length > 0 ? $" @{Stage}" : "") + (Detail.Length > 0 ? $" — {Detail}" : "");
}

// The OS pipeline: read -> precheck -> plan -> focus -> inject -> verify. Wires the PURE Switch
// decision layer (StickShift.Core) to the Windows read (WindowFocus / UiaPaneReader) + inject
// (Injector). Faithful to Switch.m's applyTuple / injectAndVerify / awaitStep ordering.
//
// Windows Terminal reality: a WT window hosts several TextPattern panes (one per tab). Reading
// "a pane by window handle" can return a DIFFERENT tab than the one SendInput hits (SendInput goes
// to the ACTIVE/foreground tab). So on COMMIT we focus the target first, then operate ENTIRELY on
// the FOCUSED pane (AutomationElement.FocusedElement) — guaranteeing read-pane == inject-pane. A
// guard reports where focus actually landed if it isn't our target (the target wasn't the active
// tab). Documented simplifications still owed (docs/WINDOWS.md step 4 / 12): full WT-UIA+Toolhelp
// process binding, the 150ms frame-age clock, the cross-process lock.
//
// Load-bearing fail-closed safety IS ported: never inject unless the classifier proves the pane a
// recognized agent, idle, not busy, no dialog, composer provably empty; every typed command is
// confirmed to LAND (occurrence delta) before the Return.
public static class SwitchDriver
{
    // tupleOverride: an explicit (model, effort) to apply — the GUI path, mirroring the macOS
    // shell's [Switch runModelToken:effort:] where the UI's tuple IS the shift and the gear
    // table is not consulted. Null (the CLI path) resolves the tuple from cfg's gear table.
    public static ShiftOutcome Shift(string targetTitle, string gear, Config cfg, bool commit, Action<string>? log = null, GearTuple? tupleOverride = null)
    {
        IntPtr target = WindowFocus.FindWindowByTitle(targetTitle);
        if (target == IntPtr.Zero)
            return new() { Reason = "NOT_TERMINAL", Stage = "RESOLVE_TARGET", Detail = $"no visible window titled *{targetTitle}*" };

        // DRY RUN: read the target by title (no focus steal), precheck, report the plan.
        if (!commit)
        {
            PaneState pane = WindowFocus.ReadPaneState(target);
            var (refusal, plan) = Precheck(pane, tupleOverride ?? cfg.TupleForGear(gear, pane.Agent), cfg);
            if (refusal != null) return refusal;
            return new() { Reason = "OK", Stage = "DRY_RUN", PlanSummary = plan!.Summary, Detail = $"would apply — {plan.Summary}" };
        }

        // COMMIT: serialize with an interprocess lock so a second client (CLI + GUI, or two quick
        // pulls) can't interleave keystrokes into the same pane. Session-local mutex; fail-closed
        // if we can't take it quickly. (WINDOWS.md step: "Named mutex (CreateMutex).")
        using var injectionGate = new Mutex(false, "StickShiftInjectionLock");
        bool lockAcquired;
        try { lockAcquired = injectionGate.WaitOne(TimeSpan.FromMilliseconds(600)); }
        catch (AbandonedMutexException) { lockAcquired = true; }   // a prior holder died mid-shift; we inherit
        if (!lockAcquired)
            return new() { Reason = "LOCKED", Stage = "PRECHECK", Detail = "another shift is in progress — try again" };
        try { return CommitShift(target, gear, cfg, log, tupleOverride); }
        finally { injectionGate.ReleaseMutex(); }
    }

    static ShiftOutcome NoFocus(string detail) => new() { Reason = "NO_FOCUS", Stage = "INJECT", Detail = detail };

    // The read -> precheck -> inject -> verify pipeline, run under the injection lock. Every keystroke
    // site re-asserts foreground AND checks it landed: if the target isn't foreground (user alt-tabbed
    // mid-shift, or SetForegroundWindow was denied), abort with NO_FOCUS BEFORE the keystroke rather
    // than blind-type Return/Escape/digits into whatever window now owns focus.
    static ShiftOutcome CommitShift(IntPtr target, string gear, Config cfg, Action<string>? log, GearTuple? tupleOverride)
    {
        // focus the target window, then operate on the FOCUSED (active) pane so the pane we read
        // is provably the pane keystrokes reach.
        if (!WindowFocus.Focus(target))
            return NoFocus("could not bring the target window to foreground");
        Thread.Sleep(150);
        log?.Invoke($"[dbg] after Focus(target): foreground='{WindowFocus.ForegroundWindowTitle()}'");

        PaneState active = WindowFocus.ReadActiveAgentPane(target);
        log?.Invoke($"[dbg] active agent pane: title='{active.WindowTitle}' agent={active.Agent} idle={active.Idle} inputEmpty={active.InputEmpty} chars={active.PaneText?.Length ?? 0}");
        if (active.Agent == AgentKind.Unknown)
            return new() { Reason = "NO_AGENT", Stage = "INJECT",
                Detail = $"after focusing, the active pane ('{active.WindowTitle}') is not a recognized agent — the target may not be the active tab; make it the visible tab and retry" };

        var (activeRefusal, activePlan) = Precheck(active, tupleOverride ?? cfg.TupleForGear(gear, active.Agent), cfg);
        if (activeRefusal != null) return activeRefusal;   // ALREADY_SET / BUSY / DRAFT etc. on the active pane
        SwitchPlan plan2 = activePlan!;

        // Baselines for the robust confirmation verify — set just before a /model or /effort is
        // injected, so the WATCH matches only a FRESH confirmation line (a stale one sits in the
        // baseline and can't false-pass).
        int modelConfirmBaseline = -1, effortConfirmBaseline = -1;

        foreach (PlanStep step in plan2.Steps)
        {
            switch (step.Kind)
            {
                case StepKind.TypeText:
                {
                    string typed = step.Text ?? "";
                    if (!Injector.CanTypeText(typed))
                        return new() { Reason = "INJECT_DROPPED", Stage = "INJECT", Detail = $"'{typed}' has a character the layout cannot type" };
                    // Delivery check (fail closed) on the FOCUSED pane: the command must appear as a
                    // NEW occurrence (an identical command in scrollback can't fake it).
                    string paneBeforeType = WindowFocus.ReadActiveAgentPane(target).PaneText ?? "";
                    int before = Switch.OccurrencesOf(typed, paneBeforeType);
                    // Robust model verify (mirrors the delivery check): baseline the "Set model to <disp>"
                    // confirmation count BEFORE injecting /model, so the WATCH can match a FRESH line
                    // (occurrence increase) even when the flaky TUI status-footer read misses it. The
                    // stale confirmation from a prior run sits in the baseline, so it can't false-pass.
                    if (typed.StartsWith("/model") && plan2.ExpectedModelDisplay != null)
                        modelConfirmBaseline = Switch.OccurrencesOf("Set model to " + plan2.ExpectedModelDisplay, paneBeforeType);
                    if (typed.StartsWith("/effort") && plan2.ExpectedEffort != null)
                        effortConfirmBaseline = Switch.OccurrencesOf("Set effort level to " + plan2.ExpectedEffort, paneBeforeType);
                    // The UIA read above transiently drops foreground to an empty window; re-assert it
                    // with NO UIA between here and SendInput so the keystrokes reliably reach the pane.
                    // Verify the re-assert: never type into a window that isn't provably foreground.
                    if (!WindowFocus.Focus(target)) return NoFocus($"target lost foreground before typing '{typed}'");
                    log?.Invoke($"[dbg] typing '{typed}' (before-count={before}); foreground='{WindowFocus.ForegroundWindowTitle()}'");
                    Injector.TypeText(typed);
                    bool landed = false;
                    for (int i = 0; i < 10 && !landed; i++)
                    {
                        Thread.Sleep(150);
                        landed = Switch.OccurrencesOf(typed, WindowFocus.ReadActiveAgentPane(target).PaneText) > before;
                    }
                    log?.Invoke($"[dbg] after typing '{typed}': landed={landed}");
                    if (!landed)
                        return new() { Reason = "INJECT_DROPPED", Stage = "INJECT", Detail = $"typed '{typed}' but it never appeared in the focused pane — keystrokes did not reach it" };
                    break;
                }
                case StepKind.Return: if (!WindowFocus.Focus(target)) return NoFocus("target lost foreground before Return"); Injector.PressReturn(); Thread.Sleep(120); break;
                case StepKind.Escape: if (!WindowFocus.Focus(target)) return NoFocus("target lost foreground before Escape"); Injector.PressEscape(); Thread.Sleep(120); break;
                case StepKind.Down: if (!WindowFocus.Focus(target)) return NoFocus("target lost foreground before Down"); Injector.PressDown(); Thread.Sleep(120); break;
                case StepKind.Up: if (!WindowFocus.Focus(target)) return NoFocus("target lost foreground before Up"); Injector.PressUp(); Thread.Sleep(120); break;
                case StepKind.Digit: if (!WindowFocus.Focus(target)) return NoFocus("target lost foreground before Digit"); Injector.PressDigit(step.Digit); Thread.Sleep(120); break;
                case StepKind.CodexSelect:
                {
                    PaneState picker = WindowFocus.ReadActiveAgentPane(target);
                    int row = PaneClassifier.CodexPickerRowFor(step.Text, picker.PaneText);
                    if (row <= 0)
                        return new() { Reason = "BAD_CONFIG", Stage = "INJECT", Detail = $"'{step.Text}' not offered in the codex picker" };
                    if (row > 9)
                        return new() { Reason = "BAD_CONFIG", Stage = "INJECT", Detail = $"picker row {row} exceeds single-digit selection" };
                    if (!WindowFocus.Focus(target)) return NoFocus("target lost foreground before picker select");
                    Injector.PressDigit(row); Thread.Sleep(150);
                    break;
                }
                case StepKind.WaitState:
                {
                    ShiftOutcome? wr = AwaitStep(step, target, cfg, plan2.ExpectedModelDisplay, modelConfirmBaseline, effortConfirmBaseline);
                    if (wr != null) return wr;
                    break;
                }
            }
        }

        // VERIFY (evidence needles, bottom-anchored) on the focused pane.
        DateTime deadline = DateTime.UtcNow.AddSeconds(2.5);
        while (DateTime.UtcNow < deadline)
        {
            string bottom = Switch.BottomLines(WindowFocus.ReadActiveAgentPane(target).PaneText, 16);
            foreach (string needle in plan2.EvidenceNeedles)
                if (bottom.Contains(needle))
                    return new() { Reason = "CHANGED", Stage = "VERIFY", Committed = true, PlanSummary = plan2.Summary, Detail = $"evidence: {needle}" };
            Thread.Sleep(200);
        }
        return new() { Reason = "UNKNOWN_FINAL_STATE", Stage = "VERIFY", Committed = true, PlanSummary = plan2.Summary, Detail = "no evidence signal by deadline" };
    }

    // Shared fail-closed precheck + plan build. Returns (refusal, null) to refuse, or (null, plan).
    // The tuple is resolved by the caller (gear table or explicit UI tuple) — agent-dependent.
    static (ShiftOutcome? refusal, SwitchPlan? plan) Precheck(PaneState pane, GearTuple? tuple, Config cfg)
    {
        if (pane.Agent == AgentKind.Unknown)
            return (new() { Reason = "NO_AGENT", Stage = "PRECHECK", Detail = "target pane is not a recognized Claude/Codex agent" }, null);
        if (pane.Busy)
            return (new() { Reason = "BUSY", Stage = "PRECHECK", Detail = "agent is busy (esc-to-interrupt / spinner present)" }, null);
        if (pane.SwitchDialogOpen)
            return (new() { Reason = "DIALOG_OPEN", Stage = "PRECHECK", Detail = "a switch dialog is already open" }, null);
        if (!pane.Idle)
            return (new() { Reason = "BUSY", Stage = "PRECHECK", Detail = "no positive idle-prompt match" }, null);
        if (!pane.InputEmpty)
            return (new() { Reason = "DRAFT_PRESENT", Stage = "PRECHECK", Detail = "composer is not provably empty" }, null);

        if (tuple is null)
            return (new() { Reason = "BAD_CONFIG", Stage = "PRECHECK", Detail = "no tuple for that gear/agent" }, null);
        SwitchPlan? plan = ShiftProtocol.PlanForKind(pane.Agent, tuple, pane.ModelText);
        if (plan is null)
            return (new() { Reason = "BAD_CONFIG", Stage = "PRECHECK", Detail = "could not build a qualified plan" }, null);

        if (Switch.PaneAlreadyAt(pane, plan.ExpectedModelDisplay, plan.ExpectedEffort))
            return (new() { Reason = "ALREADY_SET", Stage = "PRECHECK", PlanSummary = plan.Summary,
                Detail = $"already {plan.ExpectedModelDisplay}" + (plan.ExpectedEffort != null ? $" / {plan.ExpectedEffort}" : "") }, null);

        return (null, plan);
    }

    // Poll a WaitState step using the PURE Switch.DecideStep against the FOCUSED (active) pane.
    // null => Matched (success); a non-null ShiftOutcome => terminal (error / dialog / cancel / timeout).
    static ShiftOutcome? AwaitStep(PlanStep step, IntPtr target, Config cfg, string? modelDisp = null, int modelConfirmBaseline = -1, int effortConfirmBaseline = -1)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(5);
        bool confirmed = false;
        while (DateTime.UtcNow < deadline)
        {
            PaneState p = WindowFocus.ReadActiveAgentPane(target);
            // Robust verify: a FRESH confirmation line (count risen past the pre-injection baseline)
            // proves the switch landed even when the status-footer / effort-chip read misses — and,
            // unlike a bare bottom-Contains, a stale confirmation from a prior run can't false-pass.
            if (step.ExpectModel != null && modelConfirmBaseline >= 0 && !string.IsNullOrEmpty(modelDisp)
                && Switch.OccurrencesOf("Set model to " + modelDisp, p.PaneText) > modelConfirmBaseline)
                return null;
            if (step.ExpectEffort != null && effortConfirmBaseline >= 0
                && Switch.OccurrencesOf("Set effort level to " + step.ExpectEffort, p.PaneText) > effortConfirmBaseline)
                return null;
            StepDecision d = Switch.DecideStep(step, p, cfg.AutoAnswerEnabled, cfg.DialogPolicy, confirmed);
            switch (d)
            {
                case StepDecision.Matched:
                    return null;
                case StepDecision.Error:
                    return new() { Reason = step.ExpectEffort != null ? "UNSUPPORTED_EFFORT" : "BAD_CONFIG", Stage = "WATCH",
                        Detail = step.ExpectEffort != null ? "invalid effort" : "model not found" };
                case StepDecision.DialogOpen:
                    return new() { Reason = "DIALOG_OPEN", Stage = "WATCH",
                        Detail = "Claude asked to confirm the switch; confirm in the terminal or enable auto-confirm" };
                case StepDecision.Cancel:
                    if (!WindowFocus.Focus(target)) return NoFocus("target lost foreground before dialog cancel");
                    Injector.PressDigit(2);
                    return new() { Reason = "UNCHANGED", Stage = "WATCH", Detail = "cancelled per policy" };
                case StepDecision.Confirm:
                    if (!WindowFocus.Focus(target)) return NoFocus("target lost foreground before dialog confirm");
                    Injector.PressReturn(); confirmed = true; Thread.Sleep(300); continue;
                case StepDecision.Wait:
                default: break;
            }
            Thread.Sleep(180);
        }
        return new() { Reason = "UNKNOWN_FINAL_STATE", Stage = "WATCH",
            Detail = step.ExpectModel != null ? $"model did not become {step.ExpectModel}"
                   : step.ExpectEffort != null ? $"effort did not become {step.ExpectEffort}"
                   : $"did not observe '{step.Text}'" };
    }
}
