# Spike 8 findings: dialog corpus + idle/busy/empty signatures

Date: 2026-07-12. Method: PTY harness with real (minimal) API turns to trigger live
states. Claude Code 2.1.205 (default light theme), Codex 0.144.1. Raw captures in
scratchpad `spike8/`.

## BIG FINDING: the "history dialog" has changed shape in 2.1.205

The plan (and the tester's memory of the older Claude Code) assumed a 3-option dialog
("bring history as is / summarize / abort"). In 2.1.205 the mid-conversation model
switch shows a **2-option confirm** instead. Exact capture (switched Haiku→Opus after
one exchange):

```
Switch model?
Your next response will be slower and use more tokens
This conversation is cached for the current model. Switching to Opus 4.8 means the
full history gets re-read on your next message.
❯ 1. Yes, switch to Opus 4.8
  2. No, go back
```

- Anchor strings (stable): `Switch model?` (title), the two numbered options
  `1. Yes, switch to <Display>` / `2. No, go back`. The middle sentence embeds the
  TARGET display name, usable as a cross-check that the dialog belongs to OUR switch.
- Geometry: appears in the transcript area directly above the input box, drawn under
  a full-width horizontal rule (`▔▔▔…`), same region the effort/model pickers use.
- Appearance latency after Enter: **26 ms** (sub-frame; the WATCH poll interval, not
  the dialog, is the limiting factor). No history-summarize path exists to defer to.
- There is NO summarize/keep/abort branching anymore; it is confirm/cancel. This
  SIMPLIFIES M2 (item 20): the only auto-answerable decisions are "confirm" (send `1`
  or Enter) or "cancel" (send `2`). PLAN item 20's `keep`/`summarize`/`abort` policy
  values are obsolete for this version → replace with `confirm` / `cancel` / `ask`.
- Only appears when there IS cached history to invalidate; a first-message switch (no
  history) uses the plain inline path (spike 7) with no dialog. So the dialog is
  conditional and the WATCH branch must tolerate its absence (already the design).

## Claude Code idle / busy / empty signatures

- IDLE prompt: input line renders `❯ ` (U+276F) at left; a right-aligned counter
  `N tokens` sits on the same band; a full-width rule brackets the input; two-line
  statusline below: `📂 <cwd-basename>  ·  <Model Display>` and `⏸ manual mode on`
  (mode line user-dependent). Positive idle marker = the `❯` prompt glyph present AND
  no spinner glyph AND no open dialog rule.
- EMPTY-INPUT: nothing between `❯ ` and end of line. When drafting, the text follows
  `❯ `. AX value of the input element is the primary empty test (spike 3 will confirm
  Warp exposes it); this pixel/text signature is the fallback per PLAN item 13.
- BUSY: a rotating spinner glyph from the set `✻ ✽ ✢ · ✳ ✶` + a gerund
  ("Moonwalking…", "thinking", others) + a parenthetical
  `(Ns · ↓ N tokens · esc to interrupt)`. The literal substring `esc to interrupt`
  and any spinner glyph are the positive BUSY markers. DONE marker (not busy, not
  idle-yet): `✻ Cooked for Ns` then it returns to the idle prompt.
- Absence of a busy marker is NOT idle (PLAN item 13): must positively match the `❯`
  idle prompt with no spinner and no dialog rule.

## Codex idle / busy / empty signatures

- IDLE composer: bordered box header (`>_ OpenAI Codex (vX)…`), then a `›` prompt row
  showing GREYED PLACEHOLDER text that rotates ("Write tests for @filename",
  "Explain this codebase", "Use /skills to list available skills"). A persistent
  FOOTER line `<model> <effort> · <cwd>` sits below. Positive idle = footer present,
  no `• Working` line.
- EMPTY-INPUT: the `›` row shows greyed placeholder (one of the rotating hints). When
  the user types, the row shows the actual text in normal weight. Distinguishing
  placeholder vs real text by color/dim-attribute is the empty test; AX value
  preferred if Warp exposes the codex TUI input (unlikely — it is a full-screen TUI,
  so pixel/dim-attribute match is the realistic path).
- BUSY: `• Working (Ns • esc to interrupt)`. Positive BUSY markers: `• Working` and
  the literal `esc to interrupt`. (Note codex uses `•` bullet + spaces, Claude uses a
  rotating glyph — different, so per-agent signatures required, as designed.)
- Trust prompt (start-of-session, per untrusted dir):
  `Do you trust the contents of this directory?` with `1. Yes, continue / 2. No,
  quit`. Not part of a model switch, but recorded so PRECHECK can recognize and
  refuse (NOT idle) if a codex session is sitting on it.

## Theme / latency notes

- All captures at default themes; Retina/dark-theme signature capture deferred to the
  ScreenCaptureKit spike (4) where real pixels (not PTY cells) are available. PTY
  gives exact strings + geometry-in-cells; the OCR/pixel templates get built against
  real captures in spike 4/M1.
- Worst-case dialog appearance latency observed: 26 ms. Set WATCH deadline at
  spike-8 max + margin → use 2000 ms deadline, 400 ms poll (PLAN item 16) which is
  ~75x the observed latency; comfortable.

## Plan amendments required

1. Item 20: dialog policy values become `ask` (default, notify), `confirm`, `cancel`.
   Drop `keep`/`summarize`/`abort` (no longer offered by Claude 2.1.205). Auto-answer
   still ships OFF.
2. Item 16/20: the switch-confirm dialog is answerable by sending `1` (confirm) or `2`
   (cancel) or Enter (confirm, default-highlighted). Full revalidation before the key,
   per existing design.
3. Dialog match anchor set: `Switch model?` + `Yes, switch to <target-display>` +
   under-rule geometry + arrival within the window OUR switch initiated.
