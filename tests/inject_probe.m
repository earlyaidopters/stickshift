#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "Inject.h"
#import "AXState.h"
#import "Switch.h"
int main(int argc, const char **argv) { @autoreleasepool {
    pid_t term = (pid_t)atoi(argv[1]);
    NSString *needle = @"stickshift-inject-probe";
    PaneState *before = [AXState readFocusedPaneForTerminal:term];
    NSUInteger b = [Switch occurrencesOf:needle inText:before.paneText];
    if (![Inject canTypeText:needle]) { printf("UNTYPEABLE\n"); return 2; }
    [Inject typeText:needle];
    for (int i = 0; i < 10; i++) {
        usleep(200000);
        PaneState *after = [AXState readFocusedPaneForTerminal:term];
        if ([Switch occurrencesOf:needle inText:after.paneText] > b) { printf("DELIVERED\n"); return 0; }
    }
    printf("DROPPED\n"); return 1;
} }
