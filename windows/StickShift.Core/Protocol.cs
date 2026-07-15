namespace StickShift.Core;

// Faithful port of src/core/Protocol.m — the per-agent command dialects (/model, /effort,
// Codex picker rows). Pure: a plan is a function of (agent kind, gear tuple, current model),
// nothing OS-specific. docs/WINDOWS.md: "Protocol plans are properties of the agents, not the OS."

public enum StepKind
{
    TypeText, Return, Escape, Digit, Down, Up,
    WaitState,    // wait for expectedContains in pane text
    CodexSelect,  // read the codex picker, press the VERIFIED row for the label
}

public sealed class PlanStep
{
    public StepKind Kind;
    public string? Text;         // TypeText / WaitState needle / CodexSelect label
    public int Digit;
    public string? Note;
    public string? ExpectModel;  // expected status-line model display
    public string? ExpectEffort;
    public bool HandlesDialog;
    public PlanStep(StepKind kind, string? text, string? note) { Kind = kind; Text = text; Note = note; }
}

public sealed class SwitchPlan
{
    public List<PlanStep> Steps = new();
    public string? ExpectedModelDisplay;  // for no-op + verify
    public string? ExpectedEffort;        // may be null
    public List<string> EvidenceNeedles = new();  // any-of, VERIFY
    public string? Summary;
}

public static class ShiftProtocol
{
    // Status-line display name ("📂 … · <Model>") — used for verify + the no-op check.
    // NOT the longer "(1M context) (default)" form the printed "Set model to …" line uses.
    public static string ClaudeDisplayForToken(string token) => token.ToLowerInvariant() switch
    {
        "default" => "Opus 4.8",
        "opus" => "Opus 4.8",
        "sonnet" => "Sonnet 5",
        "haiku" => "Haiku 4.5",
        "fable" => "Fable 5",
        _ => token,
    };

    // Codex model picker order (spike 7). Effort order per model.
    static readonly string[] CodexModelOrder = { "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini" };
    static readonly string[] CodexEffortOrder = { "low", "medium", "high", "xhigh", "max", "ultra" };
    static int CodexModelRow(string model) { int i = Array.IndexOf(CodexModelOrder, model); return i < 0 ? -1 : i + 1; }
    static int CodexEffortRow(string effort) { int i = Array.IndexOf(CodexEffortOrder, effort); return i < 0 ? -1 : i + 1; }
    // Codex reasoning-picker DISPLAY for an effort token (xhigh renders "Extra high").
    static string CodexEffortDisplay(string effort)
    {
        if (effort == "xhigh") return "Extra high";
        return effort.Length > 0 ? char.ToUpperInvariant(effort[0]) + effort.Substring(1) : effort;
    }

    // Build a plan for (agent kind, gear tuple). Returns null if unqualified. When the pane
    // is already at the target model and the tuple carries an effort, the Claude plan skips
    // the redundant /model injection and types only /effort.
    public static SwitchPlan? PlanForKind(AgentKind kind, GearTuple tuple, string? currentModelDisplay = null)
    {
        if (string.IsNullOrEmpty(tuple.Model)) return null;
        if (!Config.IsInjectionSafe(tuple.Model)) return null;
        if (tuple.Effort != null && !Config.IsInjectionSafe(tuple.Effort)) return null;

        var p = new SwitchPlan();
        var steps = p.Steps;

        if (kind == AgentKind.Claude)
        {
            var disp = ClaudeDisplayForToken(tuple.Model);
            bool effortOnly = tuple.Effort != null && currentModelDisplay != null && currentModelDisplay == disp;
            if (!effortOnly)
            {
                steps.Add(new PlanStep(StepKind.TypeText, "/model " + tuple.Model, "type /model <token>"));
                steps.Add(new PlanStep(StepKind.Return, null, "submit model"));
                steps.Add(new PlanStep(StepKind.WaitState, "Set model to", "await model applied (handles Switch-model? dialog)")
                    { ExpectModel = disp, HandlesDialog = true });
            }
            if (tuple.Effort != null)
            {
                steps.Add(new PlanStep(StepKind.TypeText, "/effort " + tuple.Effort, "type /effort <level>"));
                steps.Add(new PlanStep(StepKind.Return, null, "submit effort"));
                steps.Add(new PlanStep(StepKind.WaitState, "Set effort level to", "await effort applied (handles Change-effort-level? dialog)")
                    { ExpectEffort = tuple.Effort, HandlesDialog = true });
            }
            p.ExpectedModelDisplay = disp;
            p.ExpectedEffort = tuple.Effort;
            p.EvidenceNeedles = effortOnly
                ? new List<string> { "Set effort level to " + tuple.Effort, $"{tuple.Effort} · /effort" }
                : new List<string> { "Set model to " + disp, $"· {disp}" };
            p.Summary = effortOnly
                ? $"claude: /effort {tuple.Effort} (already {disp})"
                : $"claude: /model {tuple.Model}" + (tuple.Effort != null ? " + /effort " + tuple.Effort : "");
        }
        else if (kind == AgentKind.Codex)
        {
            int mRow = CodexModelRow(tuple.Model);
            int eRow = tuple.Effort != null ? CodexEffortRow(tuple.Effort) : -1;
            if (mRow < 0) return null;
            steps.Add(new PlanStep(StepKind.TypeText, "/model", "type /model"));
            steps.Add(new PlanStep(StepKind.Return, null, "open popup"));
            steps.Add(new PlanStep(StepKind.WaitState, "Select Model and Effort", "await model picker"));
            // Press the VERIFIED row: read the live picker, find the row with this model's
            // label. A reordered/absent model refuses instead of mis-selecting.
            steps.Add(new PlanStep(StepKind.CodexSelect, tuple.Model, $"select model row for {tuple.Model} (label-verified)"));
            if (tuple.Effort != null)
            {
                steps.Add(new PlanStep(StepKind.WaitState, "Select Reasoning Level", "await effort stage"));
                steps.Add(new PlanStep(StepKind.CodexSelect, CodexEffortDisplay(tuple.Effort), $"select effort row for {tuple.Effort} (label-verified)"));
            }
            else
            {
                steps.Add(new PlanStep(StepKind.Return, null, "confirm current effort"));
            }
            steps.Add(new PlanStep(StepKind.WaitState, "Model changed to", "await confirmation"));
            p.ExpectedModelDisplay = tuple.Model;
            p.ExpectedEffort = tuple.Effort;
            p.EvidenceNeedles = new List<string>
            {
                $"Model changed to {tuple.Model}",
                $"{tuple.Model} {tuple.Effort ?? ""} · /",
            };
            p.Summary = $"codex picker: model row {mRow} ({tuple.Model})"
                      + (eRow > 0 ? $", effort row {eRow} ({tuple.Effort})" : "");
        }
        else return null;

        return p;
    }
}
