# Spike 4 findings: ScreenCaptureKit capture + Vision OCR fallback pipeline

Date: 2026-07-12. Code: `spikes/spike04_capture/capture.m` (ObjC). Read-only capture of
Warp's window — no keystrokes, nothing disturbed. Role after spikes 2/3: this is the
FALLBACK state source for terminals that don't expose AX text and for splits; Warp
itself uses AX text (faster, exact).

## Verdict: GO (fits the 150ms gate warm + cropped; needs launch-time warm-up)

```
frame 0 full: capture=242.4ms ocr_fast=496.2ms total=738.7ms  >150 (COLD START)
frame 0 crop: capture=242.4ms ocr_fast=42.1ms  total=284.5ms  >150 (COLD START)
frame 1 full: capture=38.8ms  ocr_fast=63.8ms  total=102.6ms  <=150 OK
frame 1 crop: capture=38.8ms  ocr_fast=29.3ms  total=68.1ms   <=150 OK
frame 2 full: capture=36.5ms  ocr_fast=61.1ms  total=97.7ms   <=150 OK
frame 2 crop: capture=36.5ms  ocr_fast=23.7ms  total=60.2ms   <=150 OK
crop OCR sample: [Other Project A] [Fable 5] …  (status line read correctly)
```

## Findings

- **In-process capture works**: `SCShareableContent` + `SCContentFilter
  initWithDesktopIndependentWindow:` + `SCScreenshotManager
  captureImageWithFilter:configuration:` returns a `CGImage` for the target window by
  PID. TCC attributes to us (screen-record already granted; `CGPreflightScreenCaptureAccess=1`).
- **Gotcha**: a bare CLI must establish a WindowServer connection first
  (`[NSApplication sharedApplication]`) or `SCScreenshotManager` asserts
  `CGS_REQUIRE_INIT`. The shipped app has this for free; the CLI must init it.
- **Warm latency (the real number)**: capture ~37ms, crop OCR (fast, bottom 25%,
  no language correction) ~24–29ms → **~60–68ms total**, well under the 150ms
  capture-to-first-injected-event gate (PLAN item 4/12). Full-window fast OCR is
  ~98–103ms warm — under gate but tighter; **crop-first is the design** (PLAN item 4
  already says so) and the data confirms it.
- **Cold start is ~740ms** (framework + Vision model warm-up on the first request).
  The FIRST switch after launch would blow the gate. Mitigation (M1): warm the
  pipeline at startup/`doctor` — one throwaway capture+OCR — so the first real switch
  is warm. Cache the Vision request/handler.
- **OCR quality**: fast level with no language correction read `Other Project A`
  (cwd) and `Fable 5` (model) correctly from the status strip. Good enough for the
  fallback's job (model + idle/busy + agent-type detection). Accurate level (slower)
  reserved for ambiguous frames only.
- Capture size was Retina-scaled (`width = points * backingScaleFactor`); multi-monitor
  and non-Retina scale variants still to be exercised in the M1 terminal matrix
  (PLAN item 9), but the pipeline and gate are proven on the primary display.

## Consequences for M1

1. State-source provider is per-terminal: Warp → AX text (sub-ms); OCR path → capture
   crop + Vision fast. Both feed the same predicate checker (idle/busy/empty/model).
2. Warm the OCR pipeline at launch; never let the first switch pay cold start.
3. Enforce the 150ms invariant at runtime: measure capture→first-injected-event; if a
   frame is stale, refuse STALE_FRAME (PLAN item 12) rather than inject.
4. Crop to the bottom status/input strip by default; full-window OCR only when the
   strip is ambiguous.
