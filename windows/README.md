# StickShift for Windows

A Windows port of StickShift following the five-step plan in [`docs/WINDOWS.md`](../docs/WINDOWS.md):
same architecture (pure decision core / OS layer / CLI / gearbox shell), same fail-closed safety
model, and the same `gearbox.html` — hosted verbatim in WebView2, not forked.

> **Status: first working version — this definitely still contains bugs.**
> It shifts real Claude Code sessions on real hardware (Windows 11 + Windows Terminal), and every
> control in the gearbox drives the engine — but it has had one evening of live testing on one
> machine. Treat it as a working spike to build on, not a hardened release. Known issues below.

## What's verified in CI

`.github/workflows/ci.yml` runs on every push/PR to `main`:

- **macOS** job: the full `make test` suite (130+ checks).
- **Windows** job (`windows-latest`): builds the entire solution, runs the 52 pure-core
  checks on real Windows, and an **OS-layer smoke test** that drives the port's *actual*
  `WindowFocus.ReadPaneState` (real UIA `TextPattern` read) and `Injector` (real
  `SendInput`) against a live console window — proving the read path classifies a real
  UIA read as a recognized idle pane, `Focus()` foregrounds the target, and injected
  keystrokes deliver and read back by occurrence delta.

That covers the mechanical OS pipeline (read → classify → focus → inject → verify). The
one thing CI can't do is install and drive a real `claude`/`codex` binary's live TUI, so
the four-step live check below still wants one human pass on a Windows box.

## Layout

| Project | WINDOWS.md step | What it is |
|---|---|---|
| `StickShift.Core` | 3 | Pure logic, no OS calls: pane classifier, gear table, switch plans, per-frame decisions. Direct port of the macOS pure modules. |
| `StickShift.Core.Tests` | 3 | 51 tests over the classifier + decision layer (real TUI fixtures, macOS and Windows frame formats). |
| `StickShift.Os` | 1, 2, 4 | UI Automation pane reader (Windows Terminal), SendInput injector (`KEYEVENTF_UNICODE`), window focus, and the fail-closed `SwitchDriver` pipeline: read → precheck → inject → verify. |
| `StickShift.Probe` | 1 | Tiny diagnostic that dumps what UIA can read from your terminal — useful when a machine behaves differently. |
| `StickShift.Cli` | — | `stickshift <gear> --target <title> [--commit]`, plus `--list`, `--dump`, `--clear-draft`. |
| `StickShift.App` | 5 | The gearbox: WebView2 shell hosting `src/app/gearbox.html` **verbatim** (linked, not copied), bridging `webkit.messageHandlers.*` → `chrome.webview.postMessage`. Applies the exact `{model, effort}` tuple the UI sends — same semantics as the macOS shell's `runModelToken:effort:`. |

## Build & run

Requirements: Windows 10/11, .NET 10 SDK, Windows Terminal, WebView2 runtime (in-box on Win 11),
Claude Code CLI.

```
cd windows
dotnet build StickShift.Windows.slnx
dotnet test  StickShift.Core.Tests/StickShift.Core.Tests.csproj
```

Give your target session a recognizable title first (`/rename my claude session` inside Claude Code).

CLI (dry-run by default; `--commit` performs the shift):

```
StickShift.Cli\bin\Debug\net10.0-windows\stickshift.exe --list
StickShift.Cli\bin\Debug\net10.0-windows\stickshift.exe 3 --target "my claude session" --commit
```

Gearbox:

```
StickShift.App\bin\Debug\net10.0-windows\StickShiftGearbox.exe --target "my claude session"
```

Pull a gate (1=Haiku, 2=Sonnet, 3=Opus, 4=Fable) or drag the throttle — the target session gets
`/model` / `/effort`, delivery-checked and verified. Esc closes; drag empty areas to move; the pin
button (Windows-shell addition, injected — not a `gearbox.html` edit) toggles always-on-top.

## Safety model (ported intact)

Never inject unless the pane is a recognized agent, idle, no dialog open, and the composer is
provably empty (`DRAFT_PRESENT` otherwise — `--clear-draft` is the deliberate way out). Every typed
command must appear as a **new** occurrence in the pane before Return (scrollback can't fake it).
Verification is needle-based on fresh confirmation lines, with occurrence baselines taken before
injection so stale lines can't false-pass.

## Windows-specific findings (why some code looks paranoid)

- **Windows Claude Code renders a different TUI than macOS**: status line is `<Model> · ctx …`
  (no `📂 cwd` footer), composer is `> ` (not `❯`), effort shows as `<effort> · /effort` — the
  classifier handles both formats.
- **Stale banners lie.** Window resizes redraw startup banners into scrollback naming whatever
  model/effort was current *then*. The classifier therefore anchors on the bottom-most live
  footer and treats banner text as display-only fallback — never as proof of current state.
- **UIA reads can transiently drop foreground focus**, so the driver re-asserts focus immediately
  before every keystroke, with no UIA call in between.
- **The effort chip is not always rendered** on Windows; when current effort can't be proven from
  the live footer, the port re-types `/effort` (idempotent) rather than trust a stale read.

## Known issues / not done yet

- **Codex path is ported but not live-tested on Windows.**
- Windows Terminal only; VS Code integrated terminals and WSL-hosted sessions are untested.
- Dialog auto-answer (`Switch model?` confirm/cancel policy) is ported but has seen little live
  exercise on Windows.
- GUI parity gaps vs macOS shell: policy choice not persisted to config, no continuous live
  refresh (state updates on launch and after shifts), no global hotkeys, no tray presence.
- One machine, one DPI, one evening of testing. Expect timing-sensitive edges in UIA reads.
