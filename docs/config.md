# StickShift configuration

Config file: `~/.stickshift/config.toml` (optional; built-in defaults are used if
absent). A copyable starting point ships at `config.example.toml` in this directory:
`cp docs/config.example.toml ~/.stickshift/config.toml`. The file must be owner-owned and not group/world-writable and not a symlink,
or StickShift refuses to load it (`BAD_CONFIG`) for mutating commands and falls back to
defaults for read-only ones.

## Keys (v1 subset)

These are the keys the parser honors. Anything else in the file is preserved but
ignored. The parser is a deliberate TOML subset: one `key = value` per line.

```toml
# How to handle Claude's mid-conversation "Switch model?" confirm dialog.
# ask     = do nothing, notify, let you decide in the terminal (DEFAULT, safest)
# confirm = auto-press "Yes, switch" (only if auto_answer = true)
# cancel  = auto-press "No, go back" (only if auto_answer = true)
dialog_policy = "ask"

# Master switch for auto-answering dialogs. Ships OFF. Enabling is opt-in.
# (The menu-bar app defaults both keys to auto-confirm when NO config file
# exists, because pulling a gear is itself the user's confirmation; its
# settings drawer writes these two keys.)
auto_answer = false

# Terminal allowlist by bundle id. Warp is the compiled-in default and the only
# terminal verified end to end. Add others after qualifying them (see AGENTS.md);
# get a bundle id with:  osascript -e 'id of app "iTerm"'
# Entries that do not look like bundle ids are skipped; an empty or fully
# invalid list keeps the default (fail closed).
enabled_terminals = ["dev.warp.Warp-Stable"]

# Gear remaps: gear.<1|2|3|4|5|R|ULTRA>.<claude|codex> = "model" or "model effort"
# Both tokens must pass the injection-safe charset below or the line is ignored.
gear.4.claude = "fable high"
gear.ULTRA.codex = "gpt-5.6-sol ultra"
```

## Gears (defaults, from spike 7)

Gears are tiers resolving to per-agent (model, effort) tuples. Values that become
keystrokes are validated against a strict charset (`[A-Za-z0-9._\[\]-]`); anything else
is rejected and never typed.

| Gear  | Claude Code            | Codex                    |
|-------|------------------------|--------------------------|
| 1     | haiku                  | gpt-5.4-mini (medium)    |
| 2     | sonnet                 | gpt-5.6-luna (medium)    |
| 3     | default (Opus 4.8 1M)  | gpt-5.6-terra (medium)   |
| 4     | fable + /effort high   | gpt-5.6-sol (high)       |
| 5     | fable + /effort max    | gpt-5.6-sol (max)        |
| R     | default + /effort auto | gpt-5.6-sol (low)        |
| ULTRA | fable + /effort ultracode | gpt-5.6-sol (ultra)   |

## Commands

```
shift <gear>            attribute the focused pane + print the plan (DRY RUN, no typing)
shift <gear> --commit   actually perform the switch
shift status            read the focused pane's agent/model/state (read-only)
shift doctor            permissions, config, and attribution self-check
```

`shift <gear>` without `--commit` never types anything — it attributes the focused
pane, runs all fail-closed prechecks, and prints what it *would* do. Use it to see the
plan and confirm attribution before committing.

## Safety model (why it refuses)

Every switch requires positive proof, from a fresh frame, of: an enabled terminal
frontmost; a recognized local agent in the focused pane; a code-signed, manifest-
qualified agent version; a positive idle-prompt match (absence of a busy marker is not
enough); and a provably empty input box. Anything uncertain returns a reason code
instead of typing. See PLAN.md for the full list.
