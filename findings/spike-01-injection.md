# Spike 1 findings: CGEvent injection delivery + timing + secure input

Date: 2026-07-12. Code: `spikes/spike01_injection/inject.m` (ObjC). Injected ONLY into
a throwaway sink window the spike owns — never into a real terminal pane — so the user's 31
live sessions were untouched.

## Verdict: GO

```
secure_input_at_start=0 can_post_events=1 ax_trusted=1
delay_0us    expected=36 received=36 match=1 mean_gap=2.31ms min=0.27 max=56.79
delay_500us  expected=36 received=36 match=1 mean_gap=0.60ms min=0.28 max=3.78
delay_2000us expected=36 received=36 match=1 mean_gap=0.51ms min=0.29 max=3.62
delay_8000us expected=36 received=36 match=1 mean_gap=0.50ms min=0.28 max=3.91
ax_readback_value="abcdefghijklmnopqrstuvwxyz0123456789" len=36
```

## Findings

- **Delivery**: `CGEventPost(kCGHIDEventTap, …)` with `CGEventKeyboardSetUnicodeString`
  (keyCode 0 + unicode payload) delivers 100% of characters into the focused first
  responder. 36/36 at every pacing including **0µs** for a native text field.
- **Unicode-string transport chosen** over keycode mapping: sending the unicode payload
  on a keyCode-0 event types arbitrary characters (letters, digits, `/`, `[`, `]`,
  `-`, `.`) without a US-layout keymap dependency. Matches PLAN item 11's strict
  charset. `\r` (Enter) needs a real keycode event (kVK_Return=36) — the injector will
  use keycode events for Enter/Esc/arrows and unicode-string for printable text.
- **Inter-key timing at the CGEvent layer**: mean gap 0.5–2.3ms, min ~0.28ms; the HID
  layer imposes no minimum. BUT this does NOT mean zero-delay is safe into agents:
  spike 7 reproduced TUI agents (codex) DROPPING a burst `\r` and immediate post-render
  arrows. The drop is in the AGENT's input parser, not the CGEvent layer. So the
  injector paces per-TARGET (a small settle + per-key OCR/AX revalidation between
  semantically distinct keys), exactly as PLAN items 12/15 require. Rule of thumb from
  data: printable text can stream fast; control keys (Enter/Esc/arrows/number-select)
  each need their own post-key verify with a settle (≥ the ~150–400ms the agent takes
  to re-render), never a blind burst.
- **AX read-back = the VERIFY path works**: after injection, reading the focused
  element's `AXValue` returned the exact typed string. This is the same mechanism used
  to verify a switch on Warp (read the focused pane's AX text). Round trip proven.
- **Secure input**: `IsSecureEventInputEnabled()` reads correctly (0 here). When a
  secure field (password/sudo prompt) holds focus it returns 1 and the OS silently
  drops synthetic key events — so PRECHECK reads it and refuses SECURE_INPUT before any
  keystroke (PLAN items 1/13). Not force-triggerable in an unattended run; behavior is
  the documented macOS contract.
- **Preflight gates** all green from the Warp-launched context: `CGPreflightPostEventAccess=1`
  (Accessibility/PostEvent), `AXIsProcessTrusted=1`, `CGPreflightScreenCaptureAccess=1`
  (from the earlier probe). TCC is satisfied for the CLI when launched under Warp.

## Not done here (deliberate), with the safe plan

- Direct keystroke injection **into a live Warp pane** was NOT performed: it would type
  into whichever of the user's 31 sessions is focused and corrupt real work. The mechanism
  is terminal-agnostic by construction (HID tap → focused app → focused element), and
  spike 6 already showed a synthesized CGEvent (mouse) reaching the right on-screen
  target with Warp frontmost. Warp keystroke confirmation is deferred to either (a) a
  dedicated scratch pane running `cat`, or (b) the `--dwell` opt-in path, both of which
  a present user can trigger without risking live sessions. M1's end-to-end test uses a
  scratch pane.

## Consequence for M1

- Injector module: `typeText(unicodeString)` (fast stream ok) + `pressKey(keyCode,
  modifiers)` for Enter/Esc/arrows/digits, each followed by the state-machine's
  per-batch revalidation. No blind timing anywhere.

## LIVE AMENDMENT (2026-07-13): Warp drops the unicode-string transport

The deferred Warp confirmation above bit in production. Live runs (see
`~/.stickshift/log`, every commit through 2026-07-13 08:44) show ZERO successful
commits: text typed via keyCode-0 + `CGEventKeyboardSetUnicodeString` NEVER appears in
a Warp pane (composer provably stayed empty; `~/.claude/settings.json` untouched),
while real-keycode events (Return, digits, the Cmd+Shift hotkeys) deliver fine. Warp
reads the KEYCODE of synthetic keyboard events and ignores the unicode payload — the
spike's 36/36 result held only for the native NSTextField sink it tested against.

Fixes shipped in the engine:
- `Inject.typeText` now resolves each char to a REAL keycode (+shift flag) under the
  current keyboard layout via `UCKeyTranslate`, attaching the unicode payload too —
  byte-for-byte what a physical key press produces. Unmapped chars fall back to the
  old transport. Coverage test: every protocol char must resolve (`core_test`).
- `Switch` verifies DELIVERY after every TypeText step (typed text must appear in the
  pane's AX text within ~1.2s) before any Return, refusing with the new
  `INJECT_DROPPED` reason instead of pressing Enter blind and surfacing a misleading
  `UNKNOWN_FINAL_STATE` at WATCH.
