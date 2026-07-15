# Windows port assessment

Status: **a first working port now exists** under [`windows/`](../windows/) (see
[`windows/README.md`](../windows/README.md)). It shifts real Claude Code sessions on
Windows 11 + Windows Terminal and follows the recommended order below step for step:
pure core ported verbatim, a UIA read + `SendInput` inject OS layer, and a WebView2
shell hosting `gearbox.html` unchanged. Treat it as an early spike — one machine, one
evening of live testing, with known gaps listed in its README (Codex path untested on
Windows, title-substring attribution instead of the full UIA-tree + Toolhelp binding,
no tray/hotkeys/live-refresh yet). The `net10.0` pure-core test suite (52 checks) runs
cross-platform and is green; the Windows-only OS/app layers need a Windows box to
verify.

This document remains the honest map for hardening that port: what carried over, what
must still be rebuilt properly, and the order that de-risks it fastest. StickShift's
engine is built on three macOS pillars (Accessibility pane reads, CGEvent keystroke
injection, TCC-gated permissions), and none of them exist on Windows in the same shape.

## What carries over unchanged

These layers were deliberately written OS-agnostic (pure functions over strings and
process tables) and port with a recompile or a mechanical translation:

- **The pane classifier** (`AXState.m`, `classifyText:`): agent detection, model and
  effort parsing, footer/banner variants, busy/idle/dialog states, composer-emptiness
  rules, placeholder vocabularies. It takes a string; it does not care where the
  string came from.
- **Protocol plans** (`Protocol.m`): the per-agent command dialects (`/model`,
  `/effort`, Codex picker rows) are properties of the agents, not the OS.
- **The state machine** (`Switch.m` decision logic): precheck ordering, delivery
  proof by occurrence delta, bottom-anchored verdicts, dialog ownership, reason codes.
- **The test suite and its fixtures**: verbatim pane captures work anywhere.
- **The gearbox UI** (`gearbox.html`): self-contained HTML/CSS/JS. On Windows it
  hosts in WebView2 instead of WKWebView; the JS bridge surface is four small
  messages (`shift`, `drag`, `resize`, `policy`).

## What must be rebuilt, layer by layer

| macOS layer | Windows replacement | Difficulty and notes |
|---|---|---|
| AX focused-window text read (`AXUIElement`) | UI Automation (UIA) `TextPattern`. Windows Terminal exposes buffer text via UIA; conhost partially. | Medium. The critical unknown to spike FIRST: does WT expose enough scrollback + the composer line, and how fast are reads. |
| CGEvent keystrokes with layout-resolved keycodes (`UCKeyTranslate`) | `SendInput` with scan codes; layout via `VkKeyScanExW` + `MapVirtualKeyExW`. | Medium. Same fail-closed rule: refuse characters the active layout cannot produce. UIPI blocks injecting into higher-integrity windows; run at the user's level. |
| tty + foreground-process-group attribution (`sysctl`, `e_tpgid`) | No ttys. Bind pane to process via WT's UIA tree + `GetWindowThreadProcessId`, then walk children with `CreateToolhelp32Snapshot`. ConPTY sessions identify the shell; the agent is a child `node.exe`. | Hard. This is the safety-critical piece. Windows Terminal panes/tabs do not map 1:1 to windows, so pane-to-process binding needs WT's own UIA structure (or its `wt.exe` session APIs). |
| Process cwd (`proc_pidvnodepathinfo`) | `NtQueryInformationProcess` -> PEB -> `CurrentDirectory`. Undocumented-but-stable; needs same-user access. | Medium. |
| Code-signature qualification (`SecStaticCode`, Developer ID teams) | Authenticode via `WinVerifyTrust`. BUT on Windows claude/codex run as scripts under `node.exe`, so binary identity is the node host, not the agent. Qualification shifts to package path + `package.json` version (already how versions resolve). | Medium; weaker guarantees than macOS, document the difference. |
| TCC Accessibility + Post-Events permission | None required for UIA reads or `SendInput` at same integrity. The permission section of the README simply disappears. | Easy (a rare win). |
| Non-activating NSPanel (never-key window) | `WS_EX_NOACTIVATE` + `WS_EX_TOPMOST` borderless window hosting WebView2. | Easy. The keyboard-routing hazard differs: `SendInput` goes to the FOREGROUND window, so the panel must never take foreground (same invariant, different API). |
| Secure-input detection (`IsSecureEventInputEnabled`) | No direct equivalent; nearest is checking for an elevated/secure-desktop foreground. | Low priority. |
| Menu-bar status item | System tray (`Shell_NotifyIcon`). | Easy. |
| `flock` switch lock | Named mutex (`CreateMutex`). | Easy. |

## Recommended port order

1. **Spike the read path** (the whole project gates on this): a probe that grabs the
   focused Windows Terminal pane's text via UIA and prints it. Feed the output to the
   existing classifier fixtures. If WT's UIA text is unusable, stop and reassess (OCR
   fallback territory). A ready-to-paste PowerShell starting point (UNTESTED, written
   on macOS; expect to iterate):

   ```powershell
   # Run in Windows PowerShell with a Windows Terminal window focused.
   Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
   $ae = [System.Windows.Automation.AutomationElement]::FocusedElement
   # Walk up to the window, then find TextPattern-capable descendants
   $cond = New-Object System.Windows.Automation.PropertyCondition(
     [System.Windows.Automation.AutomationElement]::IsTextPatternAvailableProperty, $true)
   $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
   $root = $ae
   while ($root -and $root.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window) {
     $root = $walker.GetParent($root)
   }
   $textEl = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
   if (-not $textEl) { Write-Host "NO TextPattern element found - read path is blocked"; exit 1 }
   $tp = $textEl.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
   $text = $tp.DocumentRange.GetText(100000)
   Write-Host ("read {0} chars; last 500:" -f $text.Length)
   Write-Host $text.Substring([Math]::Max(0, $text.Length - 500))
   ```

   Success criteria: the printed tail shows the agent's composer line and status
   footer with enough fidelity for `classifyText` (compare against the fixtures in
   `tests/core_test.m`).
2. **Spike injection**: `SendInput` a `/effort high` into a throwaway Claude session
   in WT; verify with the `~/.claude/settings.json` mtime trick (works on Windows at
   `%USERPROFILE%\.claude\settings.json`).
3. Port the classifier + protocol + state machine (mechanical; they are pure).
4. Build attribution on the WT UIA tree + Toolhelp child walk. This is where the
   fail-closed refusals earn their keep; port the reason codes as-is.
5. Shell: tray icon, WebView2 panel hosting `gearbox.html`, hotkeys
   (`RegisterHotKey`).
6. Qualification pass per terminal (Windows Terminal first; conhost, WezTerm, Alacritty later).

## Effort estimate

Steps 1-2 are a day and decide feasibility. A working single-terminal port is roughly
2-4 weeks of focused work, dominated by step 4 (pane-to-process attribution) and
re-verification of every fail-closed invariant against WT's actual behavior. Anyone
attempting it should read `findings/` first; every invariant there was bought with a
live failure on macOS and will have a Windows twin.
