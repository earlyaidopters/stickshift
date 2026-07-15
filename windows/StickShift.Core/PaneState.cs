namespace StickShift.Core;

// Windows port of the macOS core (src/core). This layer is the PURE logic Mark's
// docs/WINDOWS.md § "What carries over unchanged" says ports mechanically: it takes a
// string (the pane text) and does not care whether that string came from macOS AX or
// Windows UI Automation. Faithful translation of src/core/AXState.h's PaneState +
// src/core/Reason.h's reason codes.

public enum AgentKind { Unknown = 0, Claude, Codex }

// The safety vocabulary (src/core/Reason.h). Every refusal is one of these — ported
// as-is per docs/WINDOWS.md § recommended port order step 4 ("port the reason codes as-is").
public enum ReasonCode
{
    Ok = 0,
    NotTerminal, UnqualifiedTerminal, NoAgent, RemoteSession, AmbiguousAgent,
    UnsupportedAgentVersion, Busy, DraftPresent, DialogOpen, SecureInput,
    AmbiguousWindow, NoPermission, UnsupportedEffort, BadConfig, Locked,
    SelfTarget, StaleFrame, NoFocusedWindow, UnknownFinalState
}

// Parsed view of the focused terminal pane, derived from pane text. Everything the
// precondition checker needs. Mirror of PaneState in src/core/AXState.h.
public sealed class PaneState
{
    public bool HasFocusedWindow;
    public string? WindowTitle;
    public string? PaneText;
    public AgentKind Agent;
    public string? ModelText;    // e.g. "Fable 5" / "gpt-5.6-sol"
    public string? EffortText;   // e.g. "low" (codex footer), may be null
    public bool EffortLive;      // EffortText came from the LIVE footer chip, not a stale banner
    public string? CwdHint;      // basename (claude) or full path (codex)
    public bool Idle;            // positive idle-prompt match
    public bool Busy;            // positive busy marker
    public bool InputEmpty;      // provably empty input
    public bool SwitchDialogOpen;// Claude "Switch model?" dialog present
    public string? DialogTargetDisplay;
}
