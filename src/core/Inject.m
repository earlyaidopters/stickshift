#import "Inject.h"
#import <CoreGraphics/CoreGraphics.h>
#import <Carbon/Carbon.h>

@implementation Inject

static CGEventSourceRef makeSource(void) {
    return CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
}

// (keycode, shift) for a char under the CURRENT keyboard layout, built once via
// UCKeyTranslate over keycodes 0..63 (unshifted first so unshifted wins). Warp reads
// the KEYCODE of synthetic events and ignores the unicode payload, so real keycodes
// are the only transport that reaches a Warp pane; the unicode payload is still
// attached for apps that read it. Cached per process; a layout switch mid-run would
// stale it (acceptable: commands are lowercase ASCII, stable across latin layouts).
static BOOL keycodeForChar(unichar c, CGKeyCode *outKc, BOOL *outShift) {
    static NSMutableDictionary<NSNumber*, NSArray*> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSMutableDictionary dictionary];
        TISInputSourceRef layoutSrc = TISCopyCurrentKeyboardLayoutInputSource();
        CFDataRef data = layoutSrc ? TISGetInputSourceProperty(layoutSrc, kTISPropertyUnicodeKeyLayoutData) : NULL;
        if (data) {
            const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(data);
            for (int shift = 0; shift <= 1; shift++) {
                UInt32 mods = shift ? (((UInt32)shiftKey >> 8) & 0xFF) : 0;
                for (CGKeyCode kc = 0; kc < 64; kc++) {
                    UInt32 dead = 0; UniChar buf[4]; UniCharCount len = 0;
                    if (UCKeyTranslate(layout, kc, kUCKeyActionDown, mods, LMGetKbdType(),
                                       kUCKeyTranslateNoDeadKeysBit, &dead, 4, &len, buf) == noErr
                        && len == 1 && !map[@(buf[0])])
                        map[@(buf[0])] = @[@(kc), @(shift)];
                }
            }
        }
        if (layoutSrc) CFRelease(layoutSrc);
    });
    NSArray *hit = map[@(c)];
    if (!hit) return NO;
    if (outKc) *outKc = (CGKeyCode)[hit[0] intValue];
    if (outShift) *outShift = [hit[1] boolValue];
    return YES;
}

+ (BOOL)resolvesChar:(unichar)c { return keycodeForChar(c, NULL, NULL); }

+ (BOOL)canTypeText:(NSString *)s {
    if (!s.length) return NO;
    for (NSUInteger i = 0; i < s.length; i++)
        if (!keycodeForChar([s characterAtIndex:i], NULL, NULL)) return NO;
    return YES;
}

+ (BOOL)typeText:(NSString *)s {
    // Resolve the WHOLE string before posting anything: an unmapped char would need a
    // keycode-0 event, and keycode 0 is a real key ('a' on ANSI layouts) — typing a
    // wrong-but-real character into the pane is worse than refusing.
    if (![self canTypeText:s]) return NO;
    CGEventSourceRef src = makeSource();
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        CGKeyCode kc = 0; BOOL shift = NO;
        keycodeForChar(c, &kc, &shift);
        CGEventRef down = CGEventCreateKeyboardEvent(src, kc, true);
        CGEventRef up   = CGEventCreateKeyboardEvent(src, kc, false);
        if (shift) {
            CGEventSetFlags(down, kCGEventFlagMaskShift);
            CGEventSetFlags(up, kCGEventFlagMaskShift);
        }
        CGEventKeyboardSetUnicodeString(down, 1, &c);
        CGEventKeyboardSetUnicodeString(up, 1, &c);
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
        CFRelease(down); CFRelease(up);
        usleep(1500); // gentle per-char pacing; TUIs coalesce faster streams
    }
    if (src) CFRelease(src);
    return YES;
}

+ (void)pressKeycode:(CGKeyCode)kc {
    CGEventSourceRef src = makeSource();
    CGEventRef down = CGEventCreateKeyboardEvent(src, kc, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(src, kc, false);
    CGEventPost(kCGHIDEventTap, down);
    usleep(8000);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down); CFRelease(up);
    if (src) CFRelease(src);
}

+ (void)pressReturn { [self pressKeycode:(CGKeyCode)kVK_Return]; }
+ (void)pressEscape { [self pressKeycode:(CGKeyCode)kVK_Escape]; }
+ (void)pressDown   { [self pressKeycode:(CGKeyCode)kVK_DownArrow]; }
+ (void)pressUp     { [self pressKeycode:(CGKeyCode)kVK_UpArrow]; }

+ (void)pressDigit:(int)d {
    static const CGKeyCode map[10] = { kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
        kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9 };
    if (d < 0 || d > 9) return;
    [self pressKeycode:map[d]];
}

@end
