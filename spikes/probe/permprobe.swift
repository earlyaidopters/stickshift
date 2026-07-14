// Permission probe: reports the TCC-relevant state for the current
// responsible process (the terminal that launched this, e.g. Warp).
import AppKit
import ApplicationServices
import CoreGraphics

let axTrusted = AXIsProcessTrusted()
let canPostEvents = CGPreflightPostEventAccess()
let canCapture = CGPreflightScreenCaptureAccess()
let secureInput = IsSecureEventInputEnabled()

print("ax_trusted=\(axTrusted)")
print("can_post_events=\(canPostEvents)")
print("can_capture_screen=\(canCapture)")
print("secure_input_enabled=\(secureInput)")

// Who does TCC think we are? Print the responsible-ish context.
let front = NSWorkspace.shared.frontmostApplication
print("frontmost_app=\(front?.localizedName ?? "?") pid=\(front?.processIdentifier ?? -1) bundle=\(front?.bundleIdentifier ?? "?")")
