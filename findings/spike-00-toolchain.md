# Toolchain note: Swift broken, engine built in Objective-C

Date: 2026-07-12.

## Problem

The Command Line Tools Swift compiler cannot import Foundation/AppKit:
`error: redefinition of module 'SwiftBridging'`. Cause: two duplicate module maps in
`/Library/Developer/CommandLineTools/usr/include/swift/` —
`module.modulemap` (stale, Aug 2023) and `bridging.modulemap` (Apr 2025) both define
`module SwiftBridging`. They are byte-identical except a copyright year. Installing CLT
16.4 did not remove the stale one.

## The one-line fix (needs sudo; run when convenient)

```
sudo rm /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
```

(Or reinstall: `sudo rm -rf /Library/Developer/CommandLineTools && sudo xcode-select
--install`, or install full Xcode.) After that, `swiftc` against AppKit works and the
engine can be ported to Swift if desired.

## Decision: build in Objective-C now

Objective-C compiles cleanly with the SAME clang against the SAME frameworks (AppKit,
ApplicationServices/AX, CoreGraphics/CGEvent, ScreenCaptureKit, Vision, WebKit). Every
M0 spike is ObjC and all passed. PLAN said "Swift for the engine" only because the
engine needs those native APIs — ObjC satisfies that identically. So M1 ships in ObjC;
no behavior or capability is lost. Porting to Swift later (after the sudo fix) is
optional and purely cosmetic.
