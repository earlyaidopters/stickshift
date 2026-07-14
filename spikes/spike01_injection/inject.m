// Spike 1: CGEvent keystroke injection delivery + inter-key timing + secure
// input detection. Injects ONLY into a throwaway sink window this program owns.
// Uses a real AppKit run loop (NSApp run) driven by a timer so key events
// dispatch normally. Reports activation/key status so we can tell a delivery
// failure apart from a focus-acquisition failure.
//
// Build: clang -fobjc-arc -framework AppKit -framework ApplicationServices \
//        -framework Carbon inject.m -o inject
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <mach/mach_time.h>

static double ms(uint64_t d) {
    static mach_timebase_info_data_t tb; if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)d * tb.numer / tb.denom / 1e6;
}
static void injectString(NSString *s, useconds_t perKeyDelayUS) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        CGEventRef down = CGEventCreateKeyboardEvent(src, 0, true);
        CGEventRef up   = CGEventCreateKeyboardEvent(src, 0, false);
        CGEventKeyboardSetUnicodeString(down, 1, &c);
        CGEventKeyboardSetUnicodeString(up, 1, &c);
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
        CFRelease(down); CFRelease(up);
        if (perKeyDelayUS) usleep(perKeyDelayUS);
    }
    if (src) CFRelease(src);
}

@interface Ctl : NSObject
@property(nonatomic,strong) NSWindow *w;
@property(nonatomic,strong) NSTextView *tv;
@property(nonatomic,strong) NSMutableArray<NSNumber*> *stamps;
@property(nonatomic) int trial;
@end
@implementation Ctl
- (void)start {
    self.stamps = [NSMutableArray array];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent *e){
        [self.stamps addObject:@(mach_absolute_time())]; return e;
    }];
    [NSApp activateIgnoringOtherApps:YES];
    [self.w makeKeyAndOrderFront:nil];
    [self.w makeFirstResponder:self.tv];
    printf("after_activate: app_active=%d win_key=%d first_responder=%d\n",
           NSApp.isActive, self.w.isKeyWindow, self.w.firstResponder == self.tv);
    self.trial = 0;
    [self performSelector:@selector(runTrial) withObject:nil afterDelay:0.4];
}
- (void)runTrial {
    const useconds_t delays[] = {0, 500, 2000, 8000};
    const char *labels[] = {"delay_0us","delay_500us","delay_2000us","delay_8000us"};
    if (self.trial >= 4) { [self finish]; return; }
    [[self.tv textStorage] setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
    [self.stamps removeAllObjects];
    NSString *probe = @"abcdefghijklmnopqrstuvwxyz0123456789";
    uint64_t t0 = mach_absolute_time();
    injectString(probe, delays[self.trial]);
    int cur = self.trial;
    [self performSelector:@selector(reportTrial:) withObject:@[@(cur),@(t0),labels[cur]?@(cur):@(cur)] afterDelay:0.35];
    self.trial++;
}
- (void)reportTrial:(NSArray*)a {
    const char *labels[] = {"delay_0us","delay_500us","delay_2000us","delay_8000us"};
    int cur = [a[0] intValue]; uint64_t t0 = [a[1] unsignedLongLongValue];
    NSString *probe = @"abcdefghijklmnopqrstuvwxyz0123456789";
    NSString *got = self.tv.string;
    double minGap=1e9,maxGap=0,total=0; int n=0;
    for (NSUInteger i=1;i<self.stamps.count;i++){
        double g=ms(self.stamps[i].unsignedLongLongValue-self.stamps[i-1].unsignedLongLongValue);
        minGap=MIN(minGap,g);maxGap=MAX(maxGap,g);total+=g;n++;
    }
    double first = self.stamps.count? ms(self.stamps.firstObject.unsignedLongLongValue-t0):-1;
    printf("%-12s expected=%lu received=%lu match=%d first_delivery=%.1fms mean_gap=%.2fms min=%.2f max=%.2f\n",
        labels[cur],(unsigned long)probe.length,(unsigned long)got.length,[got isEqualToString:probe],
        first,n?total/n:-1,n?minGap:-1,n?maxGap:-1);
    [self performSelector:@selector(runTrial) withObject:nil afterDelay:0.1];
}
- (void)finish {
    AXUIElementRef me = AXUIElementCreateApplication(getpid());
    CFTypeRef fw=NULL; NSString *axVal=@"(none)";
    if (AXUIElementCopyAttributeValue(me,kAXFocusedUIElementAttribute,&fw)==0 && fw){
        CFTypeRef v=NULL;
        if (AXUIElementCopyAttributeValue((AXUIElementRef)fw,kAXValueAttribute,&v)==0 && v){axVal=[(__bridge id)v description];CFRelease(v);}
        CFRelease(fw);
    }
    CFRelease(me);
    printf("ax_readback_value=\"%.40s\" len=%lu\n", axVal.UTF8String,(unsigned long)axVal.length);
    printf("secure_input_at_end=%d\n", IsSecureEventInputEnabled());
    [NSApp terminate:nil];
}
@end

int main(void) {
    @autoreleasepool {
        printf("secure_input_at_start=%d can_post_events=%d ax_trusted=%d\n",
               IsSecureEventInputEnabled(), CGPreflightPostEventAccess(), AXIsProcessTrusted());
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        Ctl *c = [Ctl new];
        c.w = [[NSWindow alloc] initWithContentRect:NSMakeRect(300,400,480,260)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable
            backing:NSBackingStoreBuffered defer:NO];
        c.tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0,0,480,260)];
        c.w.contentView = c.tv;
        [c performSelector:@selector(start) withObject:nil afterDelay:0.1];
        [app run];
    }
    return 0;
}
