// Spike 6: prove a non-activating NSPanel hosting a WKWebView does not steal
// keyboard focus / does not activate our app, so the terminal stays the key
// window and keeps its AXFocusedUIElement.
//
// Build: clang -fobjc-arc -framework AppKit -framework WebKit \
//        -framework ApplicationServices panelproof.m -o panelproof
//
// Run it from Warp (so Warp is frontmost). It captures the system focus before
// showing the panel, orders the panel front WITHOUT activating, synthesizes a
// click on the WKWebView button, and re-captures focus. If the panel design is
// correct, frontmost app + focused element are unchanged and NSApp never
// activates and the panel never becomes key.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <ApplicationServices/ApplicationServices.h>
#ifndef kAXSuccess
#define kAXSuccess 0
#endif

static NSString *focusDesc(void) {
    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    pid_t fpid = front.processIdentifier;
    AXUIElementRef appEl = AXUIElementCreateApplication(fpid);
    CFTypeRef focused = NULL;
    AXError e = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute, &focused);
    NSString *role = @"?";
    if (e == kAXSuccess && focused) {
        CFTypeRef r = NULL;
        if (AXUIElementCopyAttributeValue((AXUIElementRef)focused, kAXRoleAttribute, &r) == kAXSuccess && r) {
            role = [NSString stringWithString:(__bridge NSString *)r];
            CFRelease(r);
        }
        CFRelease(focused);
    }
    CFRelease(appEl);
    return [NSString stringWithFormat:@"front=%@ pid=%d focusedRole=%@ (axErr=%d)",
            front.localizedName, fpid, role, (int)e];
}

@interface Btn : NSObject
@property(nonatomic) BOOL clicked;
@end
@implementation Btn
- (void)hit { self.clicked = YES; }
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        // Accessory: no Dock icon, never becomes the active app on its own.
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSString *before = focusDesc();

        NSRect frame = NSMakeRect(200, 200, 320, 160);
        NSPanel *panel = [[NSPanel alloc]
            initWithContentRect:frame
            styleMask:(NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskTitled |
                       NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow)
            backing:NSBackingStoreBuffered defer:NO];
        panel.floatingPanel = YES;
        panel.becomesKeyOnlyIfNeeded = YES;
        panel.hidesOnDeactivate = NO;
        panel.level = NSFloatingWindowLevel;

        WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
        WKWebView *web = [[WKWebView alloc] initWithFrame:frame configuration:cfg];
        [web loadHTMLString:@"<html><body style='margin:0;background:#222'>"
                             @"<button id='g' style='width:100%;height:100%;font-size:40px'>SHIFT</button>"
                             @"</body></html>" baseURL:nil];
        panel.contentView = web;

        // Order front WITHOUT activating or making key.
        [panel orderFrontRegardless];

        // Let the run loop process the ordering + web load briefly.
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];

        BOOL panelKeyAfterShow = panel.isKeyWindow;
        BOOL appActiveAfterShow = app.isActive;
        NSString *afterShow = focusDesc();

        // Synthesize a real left click at the panel button center via CGEvent,
        // the worst case for focus theft.
        NSPoint centerScreen = NSMakePoint(NSMidX(panel.frame), NSMidY(panel.frame));
        CGFloat screenH = NSScreen.screens.firstObject.frame.size.height;
        CGPoint cg = CGPointMake(centerScreen.x, screenH - centerScreen.y);
        CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, cg, kCGMouseButtonLeft);
        CGEventRef up   = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, cg, kCGMouseButtonLeft);
        CGEventPost(kCGHIDEventTap, down);
        usleep(30000);
        CGEventPost(kCGHIDEventTap, up);
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

        BOOL panelKeyAfterClick = panel.isKeyWindow;
        BOOL appActiveAfterClick = app.isActive;
        NSString *afterClick = focusDesc();

        printf("== Spike 6: non-activating NSPanel + WKWebView focus proof ==\n");
        printf("before_show      : %s\n", before.UTF8String);
        printf("after_show       : %s\n", afterShow.UTF8String);
        printf("after_click      : %s\n", afterClick.UTF8String);
        printf("panel_key_afterShow=%d panel_key_afterClick=%d\n", panelKeyAfterShow, panelKeyAfterClick);
        printf("app_active_afterShow=%d app_active_afterClick=%d\n", appActiveAfterShow, appActiveAfterClick);
        BOOL focusHeld = [before isEqualToString:afterShow] && [before isEqualToString:afterClick];
        BOOL neverStole = !panelKeyAfterShow && !panelKeyAfterClick && !appActiveAfterShow && !appActiveAfterClick;
        printf("RESULT focus_unchanged=%d panel_never_key_app_never_active=%d\n", focusHeld, neverStole);
        printf("VERDICT=%s\n", (focusHeld && neverStole) ? "GO" : "INVESTIGATE");
    }
    return 0;
}
