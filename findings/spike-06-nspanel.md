# Spike 6 findings: non-activating NSPanel + WKWebView focus proof

Date: 2026-07-12. Machine: macOS 15.6, arm64. Host terminal: Warp (pid 674).
Code: `spikes/spike06_nspanel/panelproof.m` (Objective-C, clang; Swift toolchain is
temporarily broken — see spike-00-toolchain note — but ObjC hits the identical
AppKit/WebKit/AX frameworks, so the proof is fully valid).

## Verdict: GO (WKWebView path works; no fallback needed)

A `NSPanel` with `NSWindowStyleMaskNonactivatingPanel`, app activation policy
`NSApplicationActivationPolicyAccessory`, hosting a live `WKWebView` button, ordered
via `orderFrontRegardless`:

```
before_show : front=Warp pid=674 focusedRole=AXTextArea (axErr=0)
after_show  : front=Warp pid=674 focusedRole=AXTextArea (axErr=0)
after_click : front=Warp pid=674 focusedRole=AXTextArea (axErr=0)
panel_key_afterShow=0 panel_key_afterClick=0
app_active_afterShow=0 app_active_afterClick=0
RESULT focus_unchanged=1 panel_never_key_app_never_active=1
VERDICT=GO
```

Test was adversarial: after ordering the panel front, the spike synthesized a REAL
`CGEvent` left click at the panel button's screen center (the worst case for focus
theft), not a soft programmatic action. Warp remained frontmost, its focused element
stayed the same `AXTextArea`, the panel never became key, and our app never activated.

## Design settings that produced this (carry into M3)

- `NSApp.setActivationPolicy(.accessory)` — no Dock icon, app cannot become active on
  its own.
- Panel style mask includes `.nonactivatingPanel`; `floatingPanel = YES`;
  `becomesKeyOnlyIfNeeded = YES`; `level = NSFloatingWindowLevel`; `hidesOnDeactivate
  = NO`.
- Show with `orderFrontRegardless`, NEVER `makeKeyAndOrderFront`.
- WKWebView as contentView did NOT force key status (the historical worry in PLAN
  item 6). No native-NSView fallback required for v1.

## Acceptance test for M3 (PLAN item 23)

The spike IS the acceptance test, automatable in CI-lite form: assert
`before == afterShow == afterClick` on `(frontmostPID, AXFocusedUIElement role)` and
assert `!panel.isKeyWindow && !NSApp.isActive` at every step. Re-run on each build.

## Bonus signal for spikes 2/3

Warp exposes a non-empty AX focused element with role `AXTextArea` (the focused
pane's input surface) and `AXUIElementCopyAttributeValue(kAXFocusedUIElementAttribute)`
returns success (axErr=0). So Warp is NOT an AX black hole for the focused-element
question — followed up in spike-02-03.

## Caveat to retest later

- WKWebView key-steal behavior can differ if the web content calls `focus()` on an
  input element or the panel is given `.titled` + text fields. Our gearbox is
  buttons/drag only (no HTML text inputs), matching the tested config. If M3 ever
  adds an HTML text field, re-run this proof.
- Retest under a full Xcode Swift build once the toolchain is fixed, to confirm the
  Swift `NSPanel` subclass behaves identically (expected: yes; same framework).
