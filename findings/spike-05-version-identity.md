# Spike 5 findings: agent version identity without executing the binary

Date: 2026-07-12. Machine: macOS 15.6 (24G84), arm64.

## Verdict: GO

Both agents expose a stable, signed, non-executing identity chain. The compatibility
manifest can key on (team identifier, code identifier, adjacent package version), with
binary SHA-256 as tiebreaker. No execution of the discovered binary is ever required.

## Claude Code (2.1.205)

- PATH entry `/opt/homebrew/bin/claude` is a symlink to
  `/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe`.
- The RUNNING process image IS that Mach-O directly (verified via `lsof -d txt` on live
  PIDs). Single-process agent; `ps comm` shows `claude`.
- Mach-O 64-bit arm64, code-signed: Identifier `com.anthropic.claude-code`,
  TeamIdentifier `Q6L2SF6YDW` (Anthropic).
- CDHash `0635ee91a8c1b326e9ee8f1d0936802b078dfa40`;
  SHA-256 `33e28624c5ae84f2bd7d2d8761e5d2e77997ba965cb11b6448de6b6e2c566f9c`.
- Version WITHOUT execution: `package.json` adjacent to the executable
  (`../package.json` relative to bin/) → `"version": "2.1.205"`.
- Identity recipe at runtime: `proc_pidpath(agentPID)` → executable path → codesign
  static validation (SecStaticCode) → team+identifier match → read adjacent
  package.json version → manifest lookup.

## Codex CLI (0.144.1)

- PATH entry `/opt/homebrew/bin/codex` → `@openai/codex/bin/codex.js`, a node ESM
  wrapper that `spawn`s the platform-native binary:
  `@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`.
- IMPORTANT for attribution (spike 3): a running Codex session is a small process
  TREE: `node …codex.js` (pgrp leader on the TTY) → native `codex` child. The
  foreground process group will contain both. Identity derivation must accept the
  agent PID being EITHER the node wrapper (image = node; identify via argv[1]
  package path) OR the native child (image = signed codex binary). Preferred: walk
  the fg pgrp members, look for the signed native binary first; fall back to the
  wrapper argv match.
- Native binary code-signed: Identifier `codex`, TeamIdentifier `2DC432GLL2` (OpenAI).
- CDHash `d03151872f950e955737aa42334e5bc513dcabc2`;
  SHA-256 `29915529b97697def1a957b0505e770aa6a45744435d62fc263e98d7619e167a`.
- Version WITHOUT execution: wrapper package `@openai/codex/package.json` → `0.144.1`;
  platform package `codex-darwin-arm64/package.json` → `0.144.1-darwin-arm64`. Both
  adjacent to their images.

## Manifest draft (format for M1)

```toml
[schema]
version = 1

[[agent]]
name = "claude-code"
team_id = "Q6L2SF6YDW"
code_identifier = "com.anthropic.claude-code"
version_source = "adjacent-package-json"   # ../package.json from bin/
qualified_versions = ["2.1.205"]           # exact-match list, extended per qualification run
protocol = "claude-slash-model-inline"     # filled by spike 7
evidence = "claude-confirmation-line"      # filled by spike 7

[[agent]]
name = "codex-cli"
team_id = "2DC432GLL2"
code_identifier = "codex"
process_shape = "node-wrapper+native-child"
version_source = "adjacent-package-json"
qualified_versions = ["0.144.1"]
protocol = ""                              # spike 7 decides inline vs picker
evidence = ""                              # spike 7
```

## Risks noted

- Homebrew upgrades swap the node_modules path contents in place; PID start time +
  executable path + CDHash in the identity tuple already guard against mid-operation
  swaps (PLAN item 12).
- If Anthropic ships claude via the native installer (`~/.claude/local/claude`), path
  differs but team/identifier stay; manifest keys on signature, not path. No
  `~/.claude/local` install present on this machine today.
- Version match is exact-list, fail-closed: unknown version → UNSUPPORTED_AGENT_VERSION.
