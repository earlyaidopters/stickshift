using StickShift.Core;

// Windows port of tests/core_test.m's classifier suite. Fixtures are the VERBATIM
// spike-capture strings from core_test.m (Mark's docs/WINDOWS.md: "the test suite and
// its fixtures: verbatim pane captures work anywhere"). Success = same verdicts the
// macOS classifier produces. Mirrors his check()/main() console-test style + exit code.

int failures = 0;
void Check(bool cond, string name)
{
    Console.WriteLine($"  [{(cond ? "PASS" : "FAIL")}] {name}");
    if (!cond) failures++;
}

PaneState Classify(string text) { var st = new PaneState(); PaneClassifier.ClassifyText(text, st); return st; }

// --- fixtures (verbatim from tests/core_test.m) ---
string ClaudeIdleEmpty =
    "⏺ pong\n" +
    "✻ Cooked for 2s\n" +
    "                                                  ◉ xhigh · /effort\n" +
    "────────────────────────────────────────────────────────────────\n" +
    "❯ \n" +
    "────────────────────────────────────────────────────────────────\n" +
    "  📂 demo-site  ·  Fable 5  ▰▰▰▱▱▱ 39%                    /rc\n" +
    "  5h: 41% (resets 18m)  7d: 31% (resets 123h 48m)\n" +
    "  ⏵⏵ bypass permissions on · 1 shell · ← for agents\n";
string ClaudeDraft = null!;
string ClaudeBusy =
    "❯ do the thing\n" +
    "✽ Moonwalking… (3s · ↓ 120 tokens · esc to interrupt)\n" +
    "  📂 demo-site  ·  Fable 5\n";
string ClaudeDialog =
    "⏺ pong\n" +
    "▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔\n" +
    "   Switch model?\n" +
    "   This conversation is cached for the current model. Switching to Opus 4.8 means…\n" +
    "   ❯ 1. Yes, switch to Opus 4.8\n" +
    "     2. No, go back\n";
string ClaudeLoopBusy =
    "✳ Fluttering… (10m 12s · ↓ 34.4k tokens)\n" +
    "  ❯ /loop 10m keep testing it\n" +
    "                                            488198 tokens\n" +
    "────────────────────────────────────────────────────────────\n" +
    "❯ Press up to edit queued messages\n" +
    "────────────────────────────────────────────────────────────\n" +
    "  📂 StickShift  ·  Opus 4.8  ▰▰▰▰▱▱ 49%              /rc\n" +
    "  ⏵⏵ bypass permissions on · ← for agents\n";
string ClaudeProseNotDialog =
    "⎿  I explained the Switch model? dialog: Yes, switch to Opus, or No, go back.\n" +
    "⎿  Set model to Haiku 4.5 and saved as your default for new sessions\n" +
    "❯ \n" +
    "────────────────────────────────────────────────────────────\n" +
    "  📂 proj  ·  Fable 5  ▰▰▱▱ 20%              /rc\n";
string CodexIdleEmpty =
    "• Ready. What would you like to work on?\n" +
    "› Explain this codebase\n" +
    "  gpt-5.6-sol low · /Users/demo/Projects/Effort Demo/codex_high\n";
string CodexBusy =
    "› analyze this\n" +
    "• Working (2s • esc to interrupt)\n" +
    "  gpt-5.6-sol low · /Users/demo/Desktop/x\n";

ClaudeDraft = ClaudeIdleEmpty.Replace("❯ \n", "❯ build the about page next\n");

Console.WriteLine("== classifier (Windows port) ==");

var a = Classify(ClaudeIdleEmpty);
Check(a.Agent == AgentKind.Claude, "claude idle: agent=claude");
Check(a.ModelText == "Fable 5", "claude idle: model=Fable 5");
Check(a.EffortText == "xhigh", "claude idle: effort=xhigh");
Check(a.CwdHint == "demo-site", "claude idle: cwd hint");
Check(a.Idle, "claude idle: idle=YES");
Check(a.InputEmpty, "claude idle: inputEmpty=YES");
Check(!a.Busy, "claude idle: busy=NO");

var d = Classify(ClaudeDraft);
Check(!d.InputEmpty, "claude draft: inputEmpty=NO (DRAFT_PRESENT)");

var b = Classify(ClaudeBusy);
Check(b.Busy, "claude busy: busy=YES");
Check(!b.Idle, "claude busy: idle=NO");

var dlg = Classify(ClaudeDialog);
Check(dlg.SwitchDialogOpen, "claude dialog: switchDialogOpen=YES");
Check(dlg.Agent == AgentKind.Claude, "claude dialog: dialog chrome alone classifies agent=claude");

var lb = Classify(ClaudeLoopBusy);
Check(lb.Busy, "claude loop: spinner without 'esc to interrupt' => busy=YES");
Check(!lb.Idle, "claude loop: idle=NO");

var pnd = Classify(ClaudeProseNotDialog);
Check(!pnd.SwitchDialogOpen, "claude prose: scrollback mentioning dialog => switchDialogOpen=NO");
Check(pnd.ModelText == "Fable 5", "claude prose: status-line model wins over scrollback 'Set model to'");

var c = Classify(CodexIdleEmpty);
Check(c.Agent == AgentKind.Codex, "codex idle: agent=codex");
Check(c.ModelText == "gpt-5.6-sol", "codex idle: model");
Check(c.EffortText == "low", "codex idle: effort=low");
Check(c.CwdHint != null && c.CwdHint.EndsWith("codex_high"), "codex idle: cwd full path");
Check(c.InputEmpty, "codex idle: placeholder => inputEmpty=YES");

var cb = Classify(CodexBusy);
Check(cb.Busy, "codex busy: busy=YES");

// === Windows Claude Code fixture (real capture 2026-07-15, session a490d858) ===
// Windows renders DIFFERENTLY from macOS: "<Model> · ctx" status line (not "📂 cwd · Model"),
// "> " composer (not "❯"), effort only in the banner "with <effort> effort", "← for agents" footer.
string WinClaudeIdle =
    "╭─── Claude Code v2.1.210 ──────────────────────────────────────────╮\n" +
    "│                Welcome back Holger!                                │\n" +
    "│      Fable 5 with high effort · Claude Max ·                       │\n" +
    "│      hugebelts@gmail.com's Organization                           │\n" +
    "│                C:\\WINDOWS\\system32                                 │\n" +
    "╰───────────────────────────────────────────────────────────────────╯\n" +
    "\n" +
    " ‼ 3 MCP servers need authentication · run /mcp\n" +
    "\n" +
    "> /rename claude code powershell\n" +
    "  ⎿  Session renamed to: claude code powershell\n" +
    "\n" +
    "──────────────────────────────────────────────── claude code powershell ──\n" +
    "> \n" +
    "───────────────────────────────────────────────────────────────────────────\n" +
    "  Fable 5 · ctx -\n" +
    "  ⏸ manual mode on · ← for agents\n";
Console.WriteLine("\n== windows claude code (real capture) ==");
var wc = Classify(WinClaudeIdle);
Check(wc.Agent == AgentKind.Claude, "win claude: agent=claude (via 'Claude Code v' + 'for agents')");
Check(wc.ModelText == "Fable 5", "win claude: model=Fable 5 (from '<Model> · ctx' / banner)");
Check(wc.EffortText == "high", "win claude: effort=high (from banner 'with high effort')");
Check(wc.Idle, "win claude: idle=YES (Windows '>' composer present, not busy)");
Check(wc.InputEmpty, "win claude: inputEmpty=YES (empty '>' composer)");
Check(!wc.Busy, "win claude: busy=NO");
// draft variant: composer with text => NOT empty
var wcDraft = Classify(WinClaudeIdle.Replace("> \n", "> build the next thing\n"));
Check(!wcDraft.InputEmpty, "win claude draft: inputEmpty=NO (DRAFT_PRESENT)");
// draft that BEGINS WITH a placeholder prefix must still be a draft, not empty: the old
// StartsWith match classified "Ask Claude about X" as an empty composer and typed over it.
var wcPlaceholderDraft = Classify(WinClaudeIdle.Replace("> \n", "> Ask Claude about the focus race\n"));
Check(!wcPlaceholderDraft.InputEmpty, "win claude draft starting with placeholder: inputEmpty=NO (exact-match, not StartsWith)");

// === Config (gear table + injection-safe charset) — port of Config.m ===
Console.WriteLine("\n== config ==");
var cfg = new Config();
var g4 = cfg.TupleForGear("4", AgentKind.Claude);
Check(g4 != null && g4.Model == "fable" && g4.Effort == "high", "gear 4 claude = fable/high");
var gu = cfg.TupleForGear("ultra", AgentKind.Codex);   // case-insensitive gear name
Check(gu != null && gu.Model == "gpt-5.6-sol" && gu.Effort == "ultra", "gear ULTRA codex = gpt-5.6-sol/ultra (case-insensitive)");
Check(cfg.TupleForGear("9", AgentKind.Claude) == null, "unknown gear => null");
Check(Config.IsInjectionSafe("fable") && Config.IsInjectionSafe("gpt-5.6-sol"), "injection-safe: normal tokens ok");
Check(!Config.IsInjectionSafe("fable; rm -rf") && !Config.IsInjectionSafe(""), "injection-safe: space/semicolon/empty refused");

// === Protocol (plan building) — port of Protocol.m ===
Console.WriteLine("\n== protocol ==");
var claudePlan = ShiftProtocol.PlanForKind(AgentKind.Claude, new GearTuple("fable", "high"));
Check(claudePlan != null && claudePlan.ExpectedModelDisplay == "Fable 5", "claude plan: model display = Fable 5");
Check(claudePlan!.Steps.Any(s => s.Text == "/model fable") && claudePlan.Steps.Any(s => s.Text == "/effort high"),
    "claude plan: has /model fable + /effort high steps");
var effortOnly = ShiftProtocol.PlanForKind(AgentKind.Claude, new GearTuple("fable", "high"), currentModelDisplay: "Fable 5");
Check(effortOnly != null && effortOnly.Steps.All(s => s.Text != "/model fable"),
    "claude plan: already at model => skips redundant /model (effort-only)");
var codexPlan = ShiftProtocol.PlanForKind(AgentKind.Codex, new GearTuple("gpt-5.6-sol", "xhigh"));
Check(codexPlan != null && codexPlan.Steps.Any(s => s.Kind == StepKind.CodexSelect && s.Text == "gpt-5.6-sol"),
    "codex plan: verified-row select for the model");
Check(codexPlan!.Steps.Any(s => s.Kind == StepKind.CodexSelect && s.Text == "Extra high"),
    "codex plan: xhigh effort renders picker label 'Extra high'");
Check(ShiftProtocol.PlanForKind(AgentKind.Codex, new GearTuple("gpt-nonexistent", null)) == null,
    "codex plan: unknown model => null (refuse, don't mis-select)");
Check(ShiftProtocol.PlanForKind(AgentKind.Claude, new GearTuple("fable; evil", null)) == null,
    "plan: injection-unsafe model => null");

// === Switch (pure decision layer) — port of Switch.m ===
Console.WriteLine("\n== switch (pure decisions) ==");
Check(Switch.DialogTargetMatchesExpected("Opus 4.8 (1M context) (default)", "Opus 4.8"),
    "dialog target: parenthesized qualifier matches (our own dialog)");
Check(!Switch.DialogTargetMatchesExpected("Opus 4.8.1", "Opus 4.8"),
    "dialog target: 'Opus 4.8.1' does NOT match 'Opus 4.8' (token boundary)");
// occurrence delta: an identical command in scrollback must not fake delivery
string scrollback = "❯ /model fable\n(earlier output)\n❯ \n";
Check(Switch.OccurrencesOf("/model fable", scrollback) == 1, "occurrences: counts the one scrollback copy");
Check(Switch.OccurrencesOf("/model fable", scrollback + "❯ /model fable\n") == 2, "occurrences: a NEW copy increases the count (delivery proof)");
// matched via classified status line
var idlePane = Classify(ClaudeIdleEmpty);   // model=Fable 5
var modelStep = new PlanStep(StepKind.WaitState, "Set model to", "") { ExpectModel = "Fable 5", HandlesDialog = true };
Check(Switch.DecideStep(modelStep, idlePane, false, DialogPolicy.Ask, false) == StepDecision.Matched,
    "decide: status line shows target model => Matched");
// dialog present, policy=ask => DialogOpen (user decides)
var dlgPane = Classify(ClaudeDialog);       // switchDialogOpen, target "Opus 4.8"
var opusStep = new PlanStep(StepKind.WaitState, "Set model to", "") { ExpectModel = "Opus 4.8", HandlesDialog = true };
Check(Switch.DecideStep(opusStep, dlgPane, false, DialogPolicy.Ask, false) == StepDecision.DialogOpen,
    "decide: our dialog + policy=ask => DialogOpen");
Check(Switch.DecideStep(opusStep, dlgPane, true, DialogPolicy.Confirm, false) == StepDecision.Confirm,
    "decide: our dialog + auto/confirm => Confirm");
// a dialog whose target is NOT ours is never auto-answered
var notOursStep = new PlanStep(StepKind.WaitState, "Set model to", "") { ExpectModel = "Sonnet 5", HandlesDialog = true };
Check(Switch.DecideStep(notOursStep, dlgPane, true, DialogPolicy.Confirm, false) == StepDecision.DialogOpen,
    "decide: dialog target not ours => DialogOpen even under auto/confirm");
// no-op check
Check(Switch.PaneAlreadyAt(idlePane, "Fable 5", "xhigh"), "alreadyAt: pane at Fable 5/xhigh => true");
Check(!Switch.PaneAlreadyAt(idlePane, "Opus 4.8", null), "alreadyAt: different model => false");

Console.WriteLine(failures == 0 ? "\nALL PASS" : $"\n{failures} FAILED");
return failures == 0 ? 0 : 1;
