#import <Foundation/Foundation.h>

// Keystroke injector. typeText streams printable text as REAL keycode events resolved
// from the current keyboard layout, with the unicode payload attached (exactly what a
// physical key press produces). Warp ignores the keycode-0 + unicode-string transport
// spike 1 validated against a native text field — text typed that way never reaches a
// Warp pane. pressKey sends a single keycode event for Enter/Esc/arrows/digits, each
// meant to be followed by the state machine's per-batch revalidation (no blind bursts).
@interface Inject : NSObject
// NO if any char lacks a real keycode under the current layout. typeText refuses such
// strings outright (fail closed) — a keycode-0 fallback would TYPE 'a' on most layouts.
+ (BOOL)canTypeText:(NSString *)s;
+ (BOOL)typeText:(NSString *)s;         // printable text via layout-resolved keycodes
+ (BOOL)resolvesChar:(unichar)c;        // can the current layout produce this char? (testable)
+ (void)pressReturn;
+ (void)pressEscape;
+ (void)pressDown;
+ (void)pressUp;
+ (void)pressDigit:(int)d;              // 1..9,0
@end
