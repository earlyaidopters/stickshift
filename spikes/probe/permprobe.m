// Permission probe: reports TCC-relevant state for the current
// responsible process (the terminal that launched this, e.g. Warp).
// Build: clang -framework AppKit -framework ApplicationServices -fobjc-arc permprobe.m -o permprobe
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

int main(void) {
    @autoreleasepool {
        printf("ax_trusted=%d\n", AXIsProcessTrusted());
        printf("can_post_events=%d\n", CGPreflightPostEventAccess());
        printf("can_capture_screen=%d\n", CGPreflightScreenCaptureAccess());
        printf("secure_input_enabled=%d\n", IsSecureEventInputEnabled());
        NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
        printf("frontmost_app=%s pid=%d bundle=%s\n",
               front.localizedName.UTF8String ?: "?",
               front.processIdentifier,
               front.bundleIdentifier.UTF8String ?: "?");
    }
    return 0;
}
