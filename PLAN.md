# StickShift Execution Plan (rev 5)

Goal: a macOS utility that switches the AI model (and effort, where qualified) of whichever agent (Claude Code or Codex CLI) is running in the currently focused terminal pane. Focus-based keystroke injection; Warp primary, any qualified terminal works. Swift engine, HTML gearbox UI.

Prime directive: **fail closed**. Every injection requires positive identification of target, local agent process, qualified agent version, idle state, and empty input box, from a fresh frame. Absence of evidence is never evidence of safety. When any check is uncertain, refuse with a reason code instead of typing.

## M0. Spikes (go/no-go gates, throwaway code, written findings each)

1. CGEvent injection into Warp running Claude Code: confirm delivery, measure inter-key delay. Verify Secure Keyboard Entry behavior (`IsSecureEventInputEnabled` → refuse).
2. Focused-pane identity: what Warp exposes via AX (focused window, focused element, pane bounds). Gate: no focused-pane bounds → Warp splits unsupported, detection refuses on detected splits; single-pane windows supported.
3. Local-process attribution (go/no-go): establish, per terminal, a positive chain from focused AX window/tab/pane → its exact local TTY → that TTY's foreground process group → agent PID (Terminal.app exposes the selected tab's tty via AX/scripting; the spike determines what Warp exposes). Terminal-wide candidate uniqueness is never sufficient attribution. Where a terminal cannot expose the focused-pane TTY, the fallback qualifies only the degenerate configuration where the UI↔TTY bijection is trivially demonstrated: exactly one window, one tab/pane, and one TTY total under the terminal, whose foreground process group is a local agent; anything else refuses AMBIGUOUS_AGENT. Agent UI visible on screen with no locally attributable agent on the focused chain → REMOTE_SESSION refusal. The attributed process is captured as an identity tuple for items 5 and 12.
4. Window capture pipeline: enumerate via ScreenCaptureKit in-process (TCC attributes to us), map frontmost PID + focused AX window to a capture target by PID + geometry; refuse on ambiguity. Measure end-to-end capture → recognition → first-injectable-event latency (the same metric item 12 enforces at runtime); acceptance gate: the full pipeline fits inside the 150ms frame-age invariant on target hardware, at Retina/non-Retina and multi-monitor scales. If recognition cannot fit the invariant, the invariant governs: runtime refuses rather than injecting on a stale frame, and the M0 gate fails until the pipeline is fast enough (crop-first OCR, cached signatures).
5. Agent version qualification without executing untrusted code: derive identity from the running process image only (resolved executable via `proc_pidpath`, code-signature/team where signed, binary hash, adjacent package metadata such as the CLI's package.json version). StickShift ships a versioned compatibility manifest mapping exact executable identities/version ranges to the validated protocol/signature/evidence sets from spikes 7-8; `doctor`'s user-confirmed trust table establishes identity persistence only and never qualifies behavior. Identity not covered by the manifest → UNSUPPORTED_AGENT_VERSION refusal. No unqualified override exists for mutating commands; read-only `status` may run degraded with an explicit UNVERIFIABLE marking.
6. NSPanel focus proof (go/no-go): stub non-activating panel with WKWebView button; prove clicking leaves the terminal as keyboard target (compare `AXFocusedUIElement` before/after). If WKWebView steals key status: fallback to plain NSView hit areas over static HTML rendering, or hotkey-only UI.
7. Model/effort command protocol per agent. Claude Code: verify `/model <value>` inline form and how effort is set (picker interaction or inline syntax); record exact accepted values. Codex: test inline argument; if picker-only, prototype OCR-label-driven selection (read visible row labels, arrow until target label is highlighted, confirm highlight via OCR, then Enter, bounded scrolling; positional offsets rejected). Output: per-agent allowlist of (model, effort) tuples, their exact injection sequences, AND a documented post-commit evidence signal for each tuple (persistent status line rendering model+effort, or the agent's printed confirmation line, e.g. Claude's "Set model to X ... with Y effort", captured during WATCH). A tuple is only enabled if both its injection sequence and its evidence signal qualified. If effort has no qualified evidence signal for an agent, gears map to model-only for that agent and ULTRA is deferred for it.
8. Claude dialog corpus: trigger the history dialog repeatedly; record exact strings, option order, geometry, worst-case appearance latency (sets watcher window). Capture idle-prompt, busy ("esc to interrupt"), and empty-input visual signatures for both agents at default themes, including cursor blink states.
9. Terminal qualification matrix (go/no-go per terminal): a terminal is only "supported" after passing all of: capture-coordinate correctness, focused-tab/window identification, AX behavior, TTY attribution (item 3), idle/empty signatures (item 8), CGEvent delivery, tabs + multiple windows, zoom/font changes, Retina scaling, permission-denied paths, mid-operation focus change. v1 candidates: Warp (single pane), Terminal.app. iTerm2 later behind a flag.
10. TCC identity: stable Developer ID signing for CLI and app (separate TCC clients, separate onboarding); verify grants persist across rebuilds, moves, Warp- and Finder-launch. `doctor` verifies both.

## M1. CLI engine: `shift` (Swift binary, shared core package)

11. Commands: `shift <gear>`, `shift status`, `shift doctor`. Config `~/.stickshift/config.toml` (versioned schema) maps gears → per-agent (model, effort) tuples. Config values are validated against the spike-7 allowlist and a strict charset (`[A-Za-z0-9._\[\]-]`, no whitespace/control chars); the injector types only allowlisted sequences, never arbitrary config strings. Config file must be owner-owned, 0600-safe, non-symlink, else refuse.
   CLI invocation semantics (the invoking shell steals focus from the target by definition): primary consumers are focus-preserving callers (the menu-bar UI, global hotkeys, Raycast/Hammerspoon-style launchers), which invoke the shared core without activating anything. Direct shell invocation detects self-targeting (attributed TTY == invoking process's TTY) and refuses with SELF_TARGET, unless run as `shift <gear> --dwell <seconds>`: the engine waits for the user to focus the agent pane, requires 500ms of stable focus on a qualifying target, then runs the normal pipeline. Both paths are tested in M1.
12. Switch pipeline is a bounded state machine: RESOLVE_TARGET → ATTRIBUTE_PROCESS → PRECHECK → INJECT → WATCH → VERIFY → REPORT. The operation target is an immutable identity tuple fixed at ATTRIBUTE_PROCESS: (terminal PID, focused window, focused element, geometry signature, agent PID, agent process start time, executable identity, TTY, foreground process group, qualified version). Immediately before every keystroke batch: fresh capture, where frame age is measured capture-to-first-injected-event and must be under 150ms or the batch refuses, revalidating the full state-specific predicate (same terminal target, expected agent UI at expected geometry, expected state: idle or the specific dialog/picker this run initiated, input empty where applicable) AND agent liveness/foreground revalidation against the identity tuple (same PID + start time still foreground on the same TTY). Any mismatch, agent exit, or restart aborts with a reason code and requires restarting from ATTRIBUTE_PROCESS. Batches minimized (command+Enter is one batch). Documented: injection cannot be atomic; revalidation shrinks the race to single-batch width.
13. Preconditions, all fail-closed: qualified terminal (spike 9); secure input off; local attributed agent process (spike 3, REMOTE_SESSION/AMBIGUOUS_AGENT otherwise); qualified version (spike 5); positive idle-prompt signature match (absence of busy marker is insufficient); input box provably empty via AX value where available, else pixel/template match against the spike-8 empty-input signature with cursor tolerance; OCR returning no text counts as unknown → refuse. Nonempty/unknown input → DRAFT_PRESENT, no destructive clearing ever.
14. Pre-injection no-op check: if `status` already shows the target (model, effort), return ALREADY_SET without injecting. Verification is defined as reaching the expected target state, not observing a transition.
15. Injection per spike-7 protocol: Claude inline `/model ...`; Codex inline if confirmed, else OCR-label picker driving with Esc-recovery if a prior partial attempt left a picker open. Unsupported (model, effort) combination for the attributed agent → UNSUPPORTED_EFFORT refusal before any keystroke.
16. WATCH is part of the core switch (not deferred to M2 sequencing): after injection, poll the focused-pane crop (interval 400ms, deadline = spike-8 max dialog latency + margin) for whichever comes first: target state reached, the history dialog, a picker state, or timeout. Dialog under `ask` policy → outcome DIALOG_OPEN (pending user decision in terminal), verification explicitly deferred, notified. Auto policy (opt-in) → answer per policy with full revalidation before each key, then verify.
17. VERIFY: bounded polling for the tuple's qualified evidence signal (spike 7: status line or printed confirmation captured during WATCH); outcomes CHANGED, ALREADY_SET, UNCHANGED (positive evidence the old tuple is still active), UNKNOWN_FINAL_STATE (evidence absent by deadline; the switch may or may not have landed; flags the tuple for requalification via `doctor`), DIALOG_OPEN (user decision pending). No retry is permitted after UNKNOWN_FINAL_STATE until a fresh successful `status` read establishes the actual current state. UNVERIFIABLE exists only for read-only status in degraded environments, never as a mutating-command completion. Anti-spoof: matches constrained to known geometry and correlated with the transition this run initiated.
18. Machine-parsable reason codes for all refusals and non-success outcomes: NOT_TERMINAL, UNQUALIFIED_TERMINAL, NO_AGENT, REMOTE_SESSION, AMBIGUOUS_AGENT, UNSUPPORTED_AGENT_VERSION, BUSY, DRAFT_PRESENT, DIALOG_OPEN, SECURE_INPUT, AMBIGUOUS_WINDOW, NO_PERMISSION, UNSUPPORTED_EFFORT, BAD_CONFIG, LOCKED, SELF_TARGET, STALE_FRAME, UNKNOWN_FINAL_STATE.
19. `shift doctor`: permission preflight both identities, attribution + version check of the focused pane, OCR self-test, Codex picker sanity, secure-input probe, config validation.

## M2. Dialog policy + state readout

20. Policy config: `ask` (default: do nothing, notify), `confirm`, `cancel`. (Revised per spike 8: Claude Code 2.1.205's mid-conversation switch is a 2-option `Switch model?` confirm — `1. Yes, switch to <Display>` / `2. No, go back` — NOT the older 3-way keep/summarize/abort, which no longer exists; those policy values are retired.) Auto-answer ships off; enabling is explicit opt-in with warning. `confirm` sends `1`/Enter, `cancel` sends `2`, each after full revalidation. Dialog match requires anchored strings (`Switch model?` + `Yes, switch to <target-display>`) AND expected under-rule geometry AND arrival within a window this run initiated; quoted dialog text in conversation fails geometry match. Dialog only appears when cached history exists; its absence on a fresh switch is expected, not an error.
21. `shift status`: agent + model + effort from focused-pane status line; UNVERIFIABLE when hidden/customized. Used for item 14's no-op check.
22. Config handling: malformed TOML → read-only commands run on defaults with warning; mutating commands refuse (BAD_CONFIG) unless `--force-defaults`.

## M3. Gearbox UI

23. Menu-bar app hosting the M0-proven panel design (or fallback). Acceptance test: clicking any gear never changes the terminal's `AXFocusedUIElement`.
24. UI calls the shared Swift core directly (no shelling out). Gears are tiers (1 cheapest → 5 max, R default) resolving to per-agent (model, effort) tuples; ULTRA lever only enabled for agents whose effort protocol qualified in spike 7.
25. Live state: refresh on NSWorkspace activation, AXObserver on focused-window/title where supported, debounced polling fallback. Displayed state is advisory; every gear click re-runs the full pipeline with fresh detection. Undetected pane → neutral display, gears disabled. Refusals surface reason codes as human-readable toasts.
26. Global hotkeys (default Cmd+Shift+1..5/R), identical pipeline.

## M4. Polish

27. Launch at login, config UI for gear remapping and dialog policy, ULTRA purple-glow easter egg, README covering both TCC onboardings and the supported-terminal matrix.

## Cross-cutting

28. Concurrency: one OS-level interprocess lock (`~/.stickshift/lock`, flock, owner-only), acquired by every client, CLI and UI. Concurrent request → LOCKED.
29. Privacy: failure screenshots opt-in, off by default; logs record state transitions, reason codes, verdicts, never OCR'd screen text unless debug mode explicitly on; `~/.stickshift` 0700, log rotation 1MB keep 3; `privacy_mode` writes no artifacts.
30. Scope refusals are enforced, not aspirational: SSH/tmux/multiplexers are caught by the spike-3 attribution rules (REMOTE_SESSION), not by guessing. Unqualified terminals refuse (UNQUALIFIED_TERMINAL).
31. Logging: timestamped state-machine transitions, reason codes, outcomes in `~/.stickshift/log` within the privacy rules.

## Build status (2026-07-12)

M0–M4 implemented and committed. All 8 throwaway spikes GO with written findings
(`findings/`). `shift` CLI + `StickShift` menu-bar app build via `make`; 30 core tests
pass (`make test`). Attribution, signature qualification, and fail-closed prechecks
verified LIVE against Warp (read-only + dry-run) across 31 concurrent agent sessions.
Two validations deferred to a user-present scratch pane (never run against the user's live
sessions): a real `--commit` keystroke injection into a focused agent, and Terminal.app
tty-join attribution. Engine is Objective-C (Swift toolchain blocked on a sudo-only
modulemap fix — `findings/spike-00-toolchain.md`).

## Spike amendments (M0 execution feedback)

- 2026-07-12, spikes 2+3 (findings/spike-02-03-attribution.md): Warp exposes the FULL
  focused-pane text via AX (`AXFocusedUIElement.AXValue` on an `AXTextArea`) — model,
  idle/busy, empty-input, agent type and cwd all readable directly, so OCR is NOT
  needed for Warp (OCR/ScreenCaptureKit demoted to the fallback for no-AX-text
  terminals and splits — rescopes spike 4). BUT Warp exposes NO pane→TTY/PID link
  (`AXDocument`/`AXProxy`/`AXURL` all empty). Attribution model for Warp changes from
  process-join to CONTENT-ANCHORED with a process safety gate: classify the agent from
  on-screen chrome, then require exactly one LOCAL manifest-qualified agent whose cwd+type
  match, else refuse (0 → REMOTE_SESSION, >1 → AMBIGUOUS_AGENT). Verified adversarially
  against 31 live sessions with duplicate cwds (Duplicate HQ ×5 → correctly AMBIGUOUS).
  Injection targets keyboard focus and VERIFY re-reads the focused pane's AX text, so the
  loop always acts on the correct on-screen pane; the process gate only enforces
  local+qualified+unambiguous. Terminal.app stays on the stronger tty-join path
  (`tty of selected tab`); attribution providers are per-terminal, state machine shared.
  Splits tentatively supported (focused sub-pane = AX focused element), upgrade from
  item 2's "splits unsupported" pending a split retest. Spike 6 confirmed the
  non-activating NSPanel + WKWebView holds focus (Warp stayed frontmost + key through a
  synthesized click) — WKWebView path qualified, no native-NSView fallback needed for v1.


- 2026-07-12, spike 7 (findings/spike-07-protocol.md): Codex 0.144.1 has NO inline
  `/model` arg (silent no-op leaving draft text); picker driving is the only path.
  Picker transport upgraded from arrows to frame-verified NUMBER keys (number read
  from same OCR frame as its label). Esc-recovery (item 15) is UNQUALIFIED for the
  codex effort stage (reproduced: Esc ignored, hint text notwithstanding); qualified
  recovery = drive the still-open picker back to the original tuple, footer-verified.
  Claude Code `/model` + `/effort` inline both qualified; both PERSIST globally
  (settings.json) except `/effort max` (session-only) — documented user-facing.
  Codex picker confirm persists to config.toml globally. Effort rows are
  model-dependent (sol has Ultra, luna does not) — per-tuple allowlists confirmed
  necessary. Codex requires text and Enter in separate batches (burst `\r`
  swallowed; reproduced) and per-keypress verify (immediate post-render arrows
  dropped; reproduced).

## Changelog

Rev 5, after Codex round 4 (gpt-5.6-sol high). Taken: TTY-less fallback attribution narrowed to the trivially bijective one-window/one-pane/one-TTY configuration (finding 1 → item 3); behavior qualification moved into a shipped compatibility manifest keyed by executable identity, doctor trust table demoted to identity persistence only, `allow_unqualified` removed for mutating commands (2 → 5, 13); frame age redefined as capture-to-first-injected-event with the M0 gate and runtime invariant unified at 150ms end-to-end (3 → 4, 12); UNKNOWN_FINAL_STATE added, UNCHANGED reserved for positive evidence, retries blocked until a fresh status read (4 → 17, 18); CLI self-targeting acknowledged and specified: focus-preserving callers are the primary path, direct shell invocation refuses SELF_TARGET or uses explicit `--dwell` stable-focus acquisition, tested in M1 (5 → 11). Rejected: nothing.

Rev 4, after Codex round 3 (gpt-5.6-sol high). Taken: attribution now requires the positive focused-pane → TTY → foreground-process-group → agent-PID chain, with terminal-wide uniqueness explicitly rejected and a strictly excluded single-session fallback for terminals that hide pane TTYs (finding 1 → items 3, 13, 30); the operation target is an immutable identity tuple including agent PID, start time, executable identity, TTY, fg pgrp, and version, revalidated for liveness/foreground before every batch with abort-and-reattribute on any change (2 → 12); version qualification never executes the discovered binary, deriving identity from the process image plus a doctor-built, user-confirmed trust table (3 → 5); every enabled (model, effort) tuple requires a qualified post-commit evidence signal, and UNVERIFIABLE is no longer an accepted completion for qualified tuples, only for explicit unqualified overrides (4 → 7, 17). Rejected: nothing.

Rev 3, after Codex round 2 (gpt-5.6-sol high). Taken: focused-pane → TTY/process-tree attribution spike with REMOTE_SESSION/AMBIGUOUS_AGENT rules replacing the aspirational SSH/tmux refusal (finding 1 → items 3, 13, 30); fresh-frame TOCTOU revalidation of the full state predicate with 150ms max frame age before every batch (2 → 12); empty-input proof via AX value or pixel/template signature match, OCR-empty treated as unknown (3 → 8, 13); config values validated against spike-derived allowlists + strict charset + secure file checks, injector never types arbitrary strings (4 → 11); runtime version qualification of the attributed process with UNSUPPORTED_AGENT_VERSION (5 → 5, 13); per-terminal qualification matrix as go/no-go gates, Terminal.app no longer presumed (6 → 9); dialog WATCH moved inside the core switch state machine before VERIFY with DIALOG_OPEN as first-class outcome (7 → 16, 17); effort switching given an explicit protocol spike, per-agent (model, effort) allowlists, UNSUPPORTED_EFFORT, and deferral when unverifiable (8 → 7, 11, 15, 24); ALREADY_SET no-op outcome and verification redefined as reaching target state (9 → 14, 17).

Rev 2, after Codex round 1: all 17 findings incorporated (focused-pane crop, M0 panel proof, per-batch revalidation, anti-spoof geometry matching, fail-closed busy check, no destructive input clearing, OCR-label Codex driving, in-process capture with ambiguity refusal, dual TCC identities, secure-input detection, tri-state verification, revalidating dialog state machine, OS-level lock, advisory UI state, privacy defaults, config refusal on malformed TOML, qualified-terminal matrix).
