namespace StickShift.Core;

// Pure subset of src/core/Config.m — the gear table, tuple resolution, and the
// injection-safe charset. File I/O (TOML load/persist, fileIsSafe, the ~/.stickshift
// config path) is the OS layer, deferred to the app project; these are the parts the plan
// builder and its tests need. Gear defaults are verbatim from spike 7.

public enum DialogPolicy { Ask = 0, Confirm, Cancel }

// A resolved (model, effort) target for one agent kind.
public sealed class GearTuple
{
    public string? Model;   // display/inline value per spike 7
    public string? Effort;  // may be null (model-only)
    public GearTuple(string? model, string? effort) { Model = model; Effort = effort; }
}

public sealed class Config
{
    public DialogPolicy DialogPolicy = DialogPolicy.Ask;
    public bool AutoAnswerEnabled = false;   // ships off
    // v1 enables Warp only (the one terminal verified end-to-end on macOS). On Windows this
    // becomes the Windows Terminal qualification; the value is a placeholder until then.
    public IReadOnlyList<string> EnabledTerminals = new[] { "dev.warp.Warp-Stable" };

    // gear -> kind -> tuple (spike 7). Claude models are inline /model args; Codex models
    // are picker labels.
    static readonly Dictionary<string, Dictionary<AgentKind, GearTuple>> Gears = new()
    {
        ["1"]     = new() { [AgentKind.Claude] = new("haiku", null),        [AgentKind.Codex] = new("gpt-5.4-mini", "medium") },
        ["2"]     = new() { [AgentKind.Claude] = new("sonnet", null),       [AgentKind.Codex] = new("gpt-5.6-luna", "medium") },
        ["3"]     = new() { [AgentKind.Claude] = new("default", null),      [AgentKind.Codex] = new("gpt-5.6-terra", "medium") },
        ["4"]     = new() { [AgentKind.Claude] = new("fable", "high"),      [AgentKind.Codex] = new("gpt-5.6-sol", "high") },
        ["5"]     = new() { [AgentKind.Claude] = new("fable", "max"),       [AgentKind.Codex] = new("gpt-5.6-sol", "max") },
        ["R"]     = new() { [AgentKind.Claude] = new("default", "auto"),    [AgentKind.Codex] = new("gpt-5.6-sol", "low") },
        ["ULTRA"] = new() { [AgentKind.Claude] = new("fable", "ultracode"), [AgentKind.Codex] = new("gpt-5.6-sol", "ultra") },
    };

    public static IReadOnlyList<string> AllGears => new[] { "1", "2", "3", "4", "5", "R", "ULTRA" };

    public GearTuple? TupleForGear(string gear, AgentKind kind)
    {
        if (kind != AgentKind.Claude && kind != AgentKind.Codex) return null;
        var up = gear.ToUpperInvariant();
        var key = Gears.ContainsKey(up) ? up : (Gears.ContainsKey(gear) ? gear : null);
        if (key == null) return null;
        return Gears[key].TryGetValue(kind, out var t) ? t : null;
    }

    // Strict charset for any value that becomes a keystroke (PLAN item 11). The injector
    // never types arbitrary strings — a value failing this is refused before any keypress.
    public static bool IsInjectionSafe(string? s)
    {
        if (string.IsNullOrEmpty(s)) return false;
        const string ok = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._[]-";
        foreach (var ch in s) if (ok.IndexOf(ch) < 0) return false;
        return true;
    }
}
