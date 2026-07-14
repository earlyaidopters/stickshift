# Spikes 2+3 findings: Warp focused-pane identity + process attribution

Date: 2026-07-12. Code: `spikes/spike0203_attribution/axdump.m`, `axdoc.m` (ObjC).
Tested against the live Warp (`dev.warp.Warp-Stable`, pid 674) with **31 concurrent
agent sessions** running — an unusually strong adversarial sample of the multi-session
case.

## Verdict: CONDITIONAL GO — Warp is usable, but the attribution MODEL must change.

The plan assumed a focused-pane → TTY → foreground-pgrp → agent-PID chain. **Warp does
not expose the TTY/PID link.** But Warp exposes something the plan did not anticipate:
the **entire focused pane's rendered text via AX**, live and correct for the pane the
user is actually looking at. That changes the design from "process-join attribution" to
"content-anchored attribution with a process safety cross-check."

## What Warp DOES expose via AX (verified)

- `AXFocusedWindow` and `AXFocusedUIElement` both resolve (axErr=0). Focused element is
  an `AXTextArea`, subrole none, frame = the pane rect.
- `AXFocusedUIElement.AXValue` = the **full rendered pane text**, including scrollback,
  the Claude/Codex status line, the input line, token counts. Example captured live:
  `📂 demo-site · Fable 5 ▰▰▰▱▱ 39%`, `❯ build the about page next`,
  `⏵⏵ bypass permissions on · 1 shell`.
  → We can read model, idle/busy, empty-input, agent type DIRECTLY from AX for Warp.
     **No ScreenCaptureKit/OCR needed for Warp** (OCR becomes the fallback for
     terminals that don't expose text, and for splits).
- Window `AXTitle` = the user's tab name (`✳ personal-website`) — user-chosen, not a
  reliable identity.
- Window `AXDescription`/`AXValueDescription` = static Warp help strings
  ("Input your shell command…", "Command Input.") — same for every pane, useless as id.

## What Warp does NOT expose (the gap)

- `AXDocument` → error -25212 (no value). `AXProxy` → -25212. `AXURL` → -25205.
- No TTY, no shell PID, no cwd path, no pane UUID anywhere in the AX tree
  (enumerated ALL attribute names on window + focused element; full list in axdump).
- Conclusion: **there is no AX-derivable focused-pane → TTY/PID link for Warp.**

## The process side (verified, independent of AX)

`sysctl(KERN_PROC_ALL)` + libproc gives, for every descendant of the terminal PID:
pid, ppid, pgid, controlling tty (`e_tdev` → `/dev/ttysNNN`), tty foreground pgrp
(`e_tpgid`), and per-pid cwd (`proc_pidinfo(PROC_PIDVNODEPATHINFO)`) and executable
image (`proc_pidpath`). The foreground agent on a tty = the process whose `pid ==
e_tpgid` (pgrp leader). This half is rock-solid and gives local/version facts.

BUT the join key back to the focused pane is only the **cwd**, and in the user's real
environment cwd is NOT unique:
- `Duplicate HQ` cwd appears **5 times** (pids 80732, 8607, 69692, 16408, 85115).
- Several `YouTube/Effort Demo/*` and duplicate `Other Project A` sessions.
So "there is only one candidate" is false here, and PLAN item 3's rule ("terminal-wide
uniqueness is never sufficient") plus the reality of duplicate cwds means a naive join
must refuse for those panes.

## Codex process shape (confirms spike 5)

Codex sessions appear as a tree on one tty: `zsh → node (codex.js wrapper, pgrp leader)
→ codex (native, signed) → node_repl / codex-code-mode-host` children. The fg pgrp
leader is the node wrapper; the signed native `codex` is a child in the same pgrp.
Attribution must walk the fg pgrp and prefer the signed native image (as spike 5 said).

## Revised attribution model for Warp (the reshaping)

Because injection targets **keyboard focus** (= the focused pane) and verification
**re-reads the focused pane's AX text**, the inject→verify loop is ALWAYS operating on
the correct on-screen pane. The process attribution's job is narrowed to a **safety
gate**: prove the focused pane is a LOCAL, qualified, UNAMBIGUOUS agent before typing.

Runtime sequence for Warp:
1. Read focused pane text (AX). Positively classify agent type + idle + empty-input +
   current model + cwd from the on-screen chrome. (No agent chrome → NOT_AGENT.)
2. Collect local foreground agents (pid==tpgid, image is a manifest-qualified
   claude/codex binary — spike 5) whose cwd matches the pane's cwd and whose type
   matches.
   - exactly 1 → ATTRIBUTED (local + version-qualifiable).
   - 0 → refuse: REMOTE_SESSION (e.g. SSH pane: local fg process is `ssh`, no local
     agent has that cwd) or unqualified. We never type when we can't bind to a local
     qualified binary.
   - >1 → refuse AMBIGUOUS_AGENT (the Duplicate HQ ×5 case).
3. Inject to focus; VERIFY by re-reading focused-pane AX (model/effort now shows target,
   or Claude's confirmation line present). Version-mismatched sequences fail closed at
   VERIFY → UNKNOWN_FINAL_STATE, no retry (PLAN item 17).

Residual risk (documented, bounded): a local agent whose cwd coincides with the cwd
shown in a focused SSH pane could pass the gate while the focused pane is remote.
Mitigations: injection + verify both act on the focused pane the user sees; a version
mismatch fails closed; and the gate still required a *local qualified* agent to exist.
Full elimination needs a real pane→TTY link Warp does not provide. **v1 ships this
model for Warp with the residual risk documented; users on multi-session SSH-heavy Warp
are told shifting refuses rather than guesses.**

## Splits

Not separately testable here (the user runs single-pane tabs), but AX gives ONE focused
`AXTextArea` = one focused pane, so a split's focused sub-pane is still the AX focused
element. Pane BOUNDS come from the AXTextArea frame. Splits are tentatively supported
via the same focused-element model; to be reconfirmed when a split is available. (This
is LESS restrictive than PLAN item 2's "splits unsupported" — upgrade pending a split
retest.)

## Gold-standard path still open: Terminal.app

PLAN keeps Terminal.app as a v1 candidate precisely because it DOES expose the selected
tab's tty via AX/AppleScript (`tty of selected tab`), giving a true pane→TTY link and
thus stronger attribution than Warp. Recommend implementing Terminal.app on the
tty-join path and Warp on the content-anchored path; the core state machine is shared,
only the RESOLVE_TARGET/ATTRIBUTE_PROCESS providers differ. (Terminal.app tty-join
retest queued for M1.)

## Plan amendments required

1. Item 2/3: record that Warp exposes NO pane→TTY link; adopt the content-anchored
   model above; keep fail-closed refusals (REMOTE_SESSION on 0 local matches,
   AMBIGUOUS_AGENT on >1). Duplicate-cwd panes refuse (verified real: Duplicate HQ ×5).
2. Item 4/12: for Warp, primary state source is AX text, not OCR; OCR/ScreenCaptureKit
   is the fallback for no-AX-text terminals and splits. Re-scope spike 4 accordingly.
3. New: attribution providers are per-terminal (Warp=content-anchored, Terminal.app=
   tty-join); the state machine is shared.
