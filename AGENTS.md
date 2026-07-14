# Agent guide: setting up and working on StickShift

You are an AI agent that has been pointed at this repo, most likely to install
StickShift on this machine, adapt it to this user's environment, or debug a refusal.
This file tells you exactly how. Read `README.md` for the full product and safety
documentation; this file is the operational playbook.

## What this is

A macOS menu-bar app + CLI that switches the model/effort of the Claude Code or Codex
CLI session in the user's focused terminal pane, by reading the pane through the
Accessibility API and typing the same commands the user would type. Everything is
fail-closed: when a proof fails, it refuses with a reason code instead of typing.

## Install on this Mac (the 95% case)

```sh
./scripts/setup.sh
```

The script is idempotent and does everything except the one step Apple reserves for
the user: checks prerequisites, creates the stable self-signed signing identity if
missing (a password prompt may appear; tell the user to expect it), builds, runs the
full test suite, installs to `~/Applications/StickShift.app`, and launches.

Then walk the user through the single manual step, exactly this sequence:

1. The app has already requested Accessibility (a system dialog appeared). Have the
   user enable StickShift in System Settings, Privacy & Security, Accessibility.
2. **Quit and relaunch the app once** (right-click the menu-bar gear, Quit, reopen).
   Grants attach at process launch; skipping the relaunch is the #1 support issue.
3. Verify: `tail -5 ~/.stickshift/log` after the user pulls a gear on a pane running
   Claude Code or Codex. `CHANGED` means done.

Do NOT "help" by manually adding TCC entries with the + button, editing the TCC
database, or re-signing ad-hoc. The signing identity + self-prompt flow exists because
those paths create stale grants (toggle shows on, permission is dead). If permissions
look wrong, the reset is: `tccutil reset Accessibility com.stickshift.gearbox`, then
relaunch the app and let it re-prompt.

## Verify an install end to end

```sh
make test                      # 130+ deterministic checks, no live panes needed
make matrix                    # qualifies THIS machine's agent binaries + all 65 UI combos
./bin/shift doctor             # permissions, config, attribution self-check
./bin/shift status             # read-only: what the focused pane looks like to the engine
./bin/shift 4                  # DRY RUN against the focused pane (types nothing)
./bin/shift 4 --commit         # the real thing (run from a DIFFERENT pane than the target)
```

`make matrix` is the fastest install-correctness signal: it discovers the installed
claude/codex binaries, checks signature + version qualification, and pushes every
(model, effort) combination through every offline pipeline stage. If it reports a
version failure, follow "Agent qualification" in `README.md` before going live.

The CLI refuses its own pane (`SELF_TARGET`), so commit-tests need two panes: the
agent pane (focused) and a shell pane you run `shift` from. Every attempt lands in
`~/.stickshift/log` with a reason code; `README.md` has the full code table.

## Adapting to this user's environment

### A different terminal (not Warp)

Warp is the only terminal verified end to end, but nothing Warp-specific is hardcoded
in the engine; the allowlist is config. Terminal.app has already passed the two
hardest gates on a stock macOS (AX pane reads classify correctly; synthetic
keystrokes deliver, proven by the engine's occurrence-count check), so it only needs
the live-session steps below.

Gates 1-2 are automated: run `./scripts/qualify-terminal.sh "<app name>"` and follow
its prompts (it renders a fake agent pane, proves the AX read path, then proves
keystroke delivery with a harmless probe string). If both pass, do steps 3-4 below
against a live agent session. The full manual procedure:

1. Add its bundle id to `~/.stickshift/config.toml`:
   `enabled_terminals = ["dev.warp.Warp-Stable", "com.googlecode.iterm2"]`
   (get the id with `osascript -e 'id of app "iTerm"'`).
2. Focus an agent pane in that terminal and run `./bin/shift status` from elsewhere.
   If it prints the right agent/model/effort, the terminal exposes its text via AX and
   reads work. If not, the terminal needs an OCR fallback or a different AX walk; stop
   and report that to the user rather than forcing it.
3. Dry-run: `./bin/shift 4`. Check every precheck passes.
4. Keystroke test in a THROWAWAY agent session (so a mis-keyed pane costs nothing):
   `./bin/shift 4 --commit`. Verify the pane actually switched AND
   `~/.claude/settings.json` mtime moved (for Claude; that file is ground truth).
   Some terminals drop synthetic keystrokes; the engine will refuse with
   `INJECT_DROPPED` rather than blind-type, which tells you the terminal is not
   drivable this way.
5. If all four pass, the terminal works for this user. Consider a PR adding it to the
   supported table in `README.md` with your findings.

### A different agent version (claude or codex updated)

The manifest pins qualified versions and will refuse others
(`UNSUPPORTED_AGENT_VERSION`). Follow "Agent qualification" in `README.md`: add the
version to `qualifiedVersions()` in `src/core/Manifest.m`, re-extract the codex
composer placeholder rotation (`strings <codex binary> | grep ...`, see
`codexPlaceholders()` in `src/core/AXState.m`), re-check footer formats against the
fixtures, then `make test`.

### Different models or gear mappings

The gear map lives in `src/core/Config.m` (`installDefaults`) and can be remapped via
`config.toml` (see `docs/config.md`). The UI's model lists live in
`src/app/AppDelegate.m` (`profileJSONForKind:`). Model tokens must pass the
injection-safe charset (`Config.isInjectionSafe`).

## Debugging a refusal

**Always start with `./bin/shift doctor`.** One command prints: permissions, config
(with the malformed warning), the app bundle's signing identity (the ad-hoc trap
diagnoses itself here), whether the app is running, the last 4 logged outcomes, and a
read-only attribution of the focused pane. Most refusals are explained by its output
alone.

Then: read the toast or `tail ~/.stickshift/log`, look the code up in `README.md`,
act. The ones with non-obvious fixes:

| Code | What to actually do |
|---|---|
| `NO_PERMISSION` | The TCC dance above. Toggle looks on but code says this: stale grant; reset + re-prompt + relaunch. |
| `KEY_FOCUS_ELSEWHERE` | Click the target pane once, retry. Keyboard focus was not on the terminal. |
| `INJECT_DROPPED` | The terminal ignored synthetic keystrokes, or a char is untypeable on the current layout. Check terminal and keyboard layout. |
| `REMOTE_SESSION` | The detail lists every tty considered and why each was rejected. Usually SSH (unsupported) or a cwd-hint mismatch; the hint is in the detail. |
| `UNSUPPORTED_AGENT_VERSION` | Qualify the new version (above). |
| `DRAFT_PRESENT` on an empty composer | A new placeholder suggestion this build doesn't know. Re-extract the placeholder list (above). |
| `UNKNOWN_FINAL_STATE` | Injection happened but verification saw nothing. Check `~/.claude/settings.json` mtime for the truth, then look at what the pane actually printed. |

## Engineering rules (locked; do not relitigate without new evidence)

- **Never** send text as keycode-0 + unicode payload. Warp drops it silently. Typing
  is layout-resolved real keycodes (`UCKeyTranslate`) only.
- **Never** let the panel become the key window (`canBecomeKeyWindow` stays NO).
  Keyboard routing follows the key window; a key panel eats the injected keystrokes.
- **Fail closed everywhere.** Unproven = refuse with a reason code. No blind timed
  keystrokes, no guessing between ambiguous sessions, no typing over drafts.
- Delivery must be proven by occurrence-count delta before any Return.
- Dialogs are only answered when provably ours (target matches expectation).
- Verdicts (success/error needles) are bottom-anchored; scrollback never counts.
- Test fixtures are verbatim live captures. When you fix a live failure, capture the
  pane text into a fixture and add the regression test in `tests/core_test.m`.
- `make test` must pass before any install; `scripts/setup.sh` enforces this.

## Repo map

See "Source map" in `README.md`. Quick anchors: engine state machine
`src/core/Switch.m`, pane classifier `src/core/AXState.m`, process binding
`src/core/Attribution.m`, plans `src/core/Protocol.m`, app shell
`src/app/AppDelegate.m`, UI `src/app/gearbox.html`, tests `tests/core_test.m`.

## Windows / Linux

Not supported. The core design (AX pane reads, CGEvent injection, TCC) is
macOS-specific. `docs/WINDOWS.md` tracks the port assessment: what carries over (the
classifier, protocol plans, and state-machine logic are OS-agnostic by design) and
what must be rebuilt (UI Automation reads, SendInput typing, terminal attribution).
If the user asks for Windows, read that file first and set expectations honestly.
