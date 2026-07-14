// Focused probe: dump the rich window-level attributes that might carry a pane
// identity (AXDocument, AXProxy, AXValue, AXDescription, AXURL, AXTitle) plus
// try to read a TTY/cwd link. Also re-reads the focused pane text so we can
// correlate against the process table in the same instant.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#ifndef kAXSuccess
#define kAXSuccess 0
#endif

static void dumpAttr(AXUIElementRef el, NSString *name) {
    CFTypeRef v = NULL;
    AXError e = AXUIElementCopyAttributeValue(el, (__bridge CFStringRef)name, &v);
    if (e != kAXSuccess || !v) { printf("  %s: <err %d>\n", name.UTF8String, (int)e); return; }
    NSString *desc;
    if (CFGetTypeID(v) == CFStringGetTypeID()) desc = (__bridge NSString *)v;
    else if (CFGetTypeID(v) == CFURLGetTypeID()) desc = [(__bridge NSURL *)v absoluteString];
    else desc = [(__bridge id)v description];
    if (desc.length > 200) desc = [[desc substringToIndex:200] stringByAppendingString:@"…"];
    printf("  %s: %s\n", name.UTF8String, [desc stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"].UTF8String);
    CFRelease(v);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        pid_t pid = argc > 1 ? (pid_t)atoi(argv[1]) : 0;
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        CFTypeRef win = NULL;
        if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &win) != kAXSuccess || !win) {
            printf("no focused window\n"); return 1;
        }
        printf("== focused window rich attributes ==\n");
        for (NSString *a in @[@"AXTitle", @"AXDocument", @"AXProxy", @"AXURL",
                              @"AXDescription", @"AXValueDescription", @"AXRoleDescription",
                              @"AXSections", @"AXValue"]) {
            dumpAttr((AXUIElementRef)win, a);
        }
        // AXProxy sometimes is itself an element with more attrs
        CFTypeRef proxy = NULL;
        if (AXUIElementCopyAttributeValue((AXUIElementRef)win, CFSTR("AXProxy"), &proxy) == kAXSuccess && proxy
            && CFGetTypeID(proxy) == AXUIElementGetTypeID()) {
            printf("== AXProxy sub-attributes ==\n");
            CFArrayRef names = NULL;
            if (AXUIElementCopyAttributeNames((AXUIElementRef)proxy, &names) == kAXSuccess && names) {
                for (CFIndex i = 0; i < CFArrayGetCount(names); i++)
                    dumpAttr((AXUIElementRef)proxy, (__bridge NSString *)CFArrayGetValueAtIndex(names, i));
                CFRelease(names);
            }
        }
        if (proxy) CFRelease(proxy);
        CFRelease(win);
        CFRelease(app);
    }
    return 0;
}
