# Spike 7 findings: model/effort command protocol per agent

Date: 2026-07-12. Method: PTY expect-harness (`spikes/ptydrive.py`, pyte-rendered
screens, timestamped event stream). Raw captures in session scratchpad `spike7/`.
Claude Code 2.1.205, Codex CLI 0.144.1. Both agents' persisted defaults were backed up
and restored after testing.

## Verdict: GO for both agents, model AND effort, with protocol differences below.

## Claude Code 2.1.205

INLINE, first-class. Two separate commands; compound form does not exist.

- `/model <value>` accepted values (verified): `default`, `opus`, `sonnet`, `haiku`,
  `fable` (implied by picker; alias verified via picker ✔ row), `sonnet[1m]`,
  full IDs like `claude-fable-5[1m]`. Case: lowercase tested.
- Rejection: `/model not-a-real-model-xyz` → `Model 'not-a-real-model-xyz' not found`.
  No state change. Safe failure.
- `/model fable max` → `Model 'fable max' not found`. NO compound model+effort inline.
- `/effort <value>` accepted values (from its own error message, authoritative):
  `low, medium, high, xhigh, max, ultracode, auto`.
- PERSISTENCE WARNING: both commands print `saved as your default for new sessions`
  and write `model` / `effortLevel` into `~/.claude/settings.json` — switching the
  focused session ALSO changes the user's global default. Exception: `/effort max`
  printed `(this session only)`. Session-only alternative: the picker's `s` key
  ("s to use this session only"). StickShift default should PREFER the `s` path via
  picker for claude when the user opts for session-only semantics; v1 ships inline
  (global persist) with this documented.
- Evidence signals (VERIFY):
  - `⎿  Set model to <Display> and saved as your default for new sessions`
    (Display: `Sonnet 5`, `Opus 4.8 (1M context)`, `Haiku 4.5`, `Fable 5`,
    `Opus 4.8 (1M context) (default)`).
  - `⎿  Set effort level to <level> (saved as your default for new sessions): …` or
    `(this session only): …`.
  - Failure: `Model 'X' not found` / `Invalid argument: X. Valid options are: …`.
  - Cancel: `Kept model as <Display>` (printed when picker dismissed with Esc) /
    `Cancelled` (effort dialog Esc).
  - Persistent chip right-above input: `◉ xhigh · /effort` (◉/○ varies by level).
  - Statusline (user-configurable, secondary only): shows model display name.
- `/model` bare opens picker: title `Select model`, numbered rows 1-5
  (Default/Opus/Fable/Sonnet/Haiku), `❯` marker + `✔` on current, effort slider row
  (`←/→ to adjust`), footer `Enter to set as default · s to use this session only ·
  Esc to cancel`. `/effort` bare opens an `Effort` slider dialog
  (low—medium—high—xhigh—max—ultracode), `←/→`, Enter, Esc → `Cancelled`.
- Latency (PTY, in-terminal render): inline confirmation ~36 ms after Enter;
  picker render ~26 ms. Sub-frame. WATCH deadlines will be dominated by
  capture+OCR, not the agent.

## Codex CLI 0.144.1

NO INLINE. Picker driving only.

- `/model <anything>` + Enter is a SILENT NO-OP: the text stays in the composer,
  nothing executes, no error (tested with valid `gpt-5.6-luna` and invalid names).
  The leftover text remains as a draft → our DRAFT_PRESENT precondition will refuse
  next time; recovery/cleanup of our own leftover is an M1 concern.
- Burst-timing hazard (reproduced): sending `/model\r` as ONE write can swallow the
  `\r` (slash-popup race) — command text and Enter MUST be separate batches with
  settle + OCR revalidation between them. Same for immediately-after-render arrow
  keys: two down-arrows sent right after picker render were DROPPED (reproduced);
  arrows sent ≥0.8 s after render worked. Every keypress needs its own
  verify-after-press loop, exactly as PLAN item 15 prescribes.
- Picker flow: `/model` → popup (`/model  choose what model and reasoning effort to
  use`) → Enter → `Select Model and Effort` list:
  1 gpt-5.6-sol, 2 gpt-5.6-terra, 3 gpt-5.6-luna, 4 gpt-5.5, 5 gpt-5.4, 6 gpt-5.4-mini
  (order/list will drift with releases; manifest pins per version).
- NUMBER KEYS select AND advance in one keystroke (pressing `3` selected luna and
  jumped straight to its effort stage). Preferred transport: OCR the rows from a
  fresh frame, map target label → its rendered number, press that number. This is
  label-verified, not positional: the number is read from the SAME frame.
- Effort stage: `Select Reasoning Level for <model>`; rows are MODEL-DEPENDENT:
  sol shows Low/Medium (default)/High/Extra high/Max/Ultra (6);
  luna shows only 5 (no Ultra). Confirms per-(model,effort) tuple qualification.
- CRITICAL: Esc did NOT leave the effort stage despite the hint `esc to go back`
  (two lone-Esc presses, 1 s apart, no state change; subsequent typed chars were
  swallowed; a later Enter CONFIRMED the highlighted row and switched the model).
  Esc-recovery is NOT qualified for codex pickers. Amend PLAN item 15: recovery from
  a partially-open codex picker must be OCR-verified, and the qualified recovery
  path is completing the picker back to the ORIGINAL tuple (footer-verified), not Esc.
- PERSISTENCE: picker confirm writes `model` and `model_reasoning_effort` to
  `~/.codex/config.toml` (global default for all future sessions) and records
  per-dir trust under `[projects."<dir>"]`.
- Evidence signals (VERIFY):
  - Transcript line `• Model changed to <model> <effort>` — printed on every confirm
    INCLUDING no-op re-confirmation of the current tuple. It proves final state, not
    transition. Matches PLAN item 14/17 semantics (verify target state, not change).
  - PERSISTENT FOOTER `<model> <effort> · <cwd>` (e.g. `gpt-5.6-sol low · /path`) —
    always on screen, updates immediately. Primary runtime evidence for codex.
  - `/status` → boxed readout incl. `Model: gpt-5.6-sol (reasoning low, summaries
    auto)` — usable for ALREADY_SET precheck and `shift status`.
  - Unknown command: `• Unrecognized command '/xyz'. Type "/" for a list…`.
- Latency: picker render ~3 ms after Enter; `Model changed` ~49 ms after confirm.
- Trust dialog (`Do you trust the contents of this directory?`) appears once per
  untrusted dir at codex START (not during /model) — not a WATCH concern for
  switching, but recorded for the corpus.

## Gear map consequence (PLAN items 7, 24)

Both agents qualify for model AND effort switching in v1:

| Gear | Claude Code | Codex |
|------|-------------|-------|
| 1 | haiku | gpt-5.4-mini |
| 2 | sonnet | gpt-5.6-luna |
| 3 | default (Opus 4.8 1M) | gpt-5.6-terra |
| 4 | fable | gpt-5.6-sol (high) |
| 5 | fable + /effort max | gpt-5.6-sol (max) |
| R | default + /effort auto | config.toml defaults |
| ULTRA | fable + /effort ultracode | gpt-5.6-sol (Ultra) |

(Defaults for config; user-remappable. Codex effort chosen in the same picker pass,
no extra command.)

## Injection sequences (for the manifest)

- claude.model: type `/model <value>`, verify composer content via OCR, Enter,
  WATCH for `Set model to` | `not found`.
- claude.effort: type `/effort <value>`, verify, Enter, WATCH for
  `Set effort level to` | `Invalid argument`.
- codex.tuple: type `/model`, verify popup row highlighted, Enter, WATCH for
  `Select Model and Effort`, OCR rows → press number of target model label, WATCH
  for `Select Reasoning Level for <target-model>`, OCR rows → press number of
  target effort label, WATCH for `Model changed to <model> <effort>` + footer match.
  On any mismatch: freeze (no Esc), reattribute, and if our picker is still open,
  drive it back to the original tuple.
