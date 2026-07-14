# Spikes 9 + 10 status: terminal qualification matrix + TCC identity

Date: 2026-07-12. These two are aggregation/packaging gates that depend on the built
app, so they are partially resolved now and folded into M1 rather than throwaway spikes.

## Spike 9 — terminal qualification matrix

Status: Warp characterized (GO with content-anchored model); Terminal.app queued.

Warp (`dev.warp.Warp-Stable`) results gathered across spikes 1-8, mapped to item 9's
checklist:
- capture-coordinate correctness: OK (spike 4, window frame → capture rect).
- focused-tab/window identification: OK (spike 2, AXFocusedWindow/Element resolve).
- AX behaviour: RICH — full pane text via AX (spike 2), better than expected.
- TTY attribution: NOT via AX (spike 3) → content-anchored model + process safety gate.
- idle/empty signatures: captured (spike 8) — Claude `❯` + statusline, Codex footer.
- CGEvent delivery: OK (spike 1), 100% at all pacings.
- tabs + multiple windows: partial — 31 sessions observed across tabs; focused element
  tracks the visible pane correctly.
- zoom/font/Retina: capture is scale-aware (spike 4); explicit font/zoom sweep → M1.
- permission-denied paths: preflight readable (spikes 1/4); refusal wiring → M1.
- mid-operation focus change: the design's per-batch revalidation covers it; the
  runtime test belongs to M1 with the real state machine.

Terminal.app: deferred to M1 on the stronger tty-join path (`tty of selected tab` via
AppleScript/AX gives a true pane→TTY link; implement its attribution provider then and
run the same matrix). iTerm2 behind a flag, later.

Decision: v1 ships **Warp (content-anchored)** as primary + **Terminal.app (tty-join)**
once its provider passes the matrix in M1. Both share the core state machine; only the
RESOLVE_TARGET/ATTRIBUTE_PROCESS/state-source providers differ.

## Spike 10 — TCC identity + signing persistence

Status: functional now (dev context); stable Developer ID + persistence is an M1/M4
packaging task.

- Current: the ad-hoc/CLT-built binaries launched under Warp already hold the needed
  grants in this environment (`AXIsProcessTrusted=1`, `CGPreflightPostEventAccess=1`,
  `CGPreflightScreenCaptureAccess=1`). Good enough to build and test M1.
- For release: the CLI (`shift`) and the menu-bar app are SEPARATE TCC clients and need
  SEPARATE onboarding (Accessibility + Screen Recording each). Stable Developer ID
  signing is required so grants persist across rebuilds/moves; ad-hoc signing changes
  identity every build and drops grants. `doctor` verifies both identities.
- Action for M1/M4: sign both products with a stable Developer ID, verify grant
  persistence across rebuild + move + Warp-launch + Finder-launch, and wire `doctor`
  to preflight both. Until a Developer ID cert is available, development uses a stable
  ad-hoc identity with a fixed designated requirement to avoid re-granting each build.

## Net M0 gate status

All eight throwaway spikes (1-8) are GO with written findings. The two design-reshaping
gates (6 NSPanel, 2/3 attribution) are resolved. 9 and 10 are qualification/packaging
gates that continue inside M1. **Clear to start M1.**
