// Offscreen render of the gearbox to a PNG for visual verification (no menu-bar/panel
// intrusion). Loads gearbox.html, pushes sample state, snapshots the WKWebView.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

@interface R : NSObject <WKNavigationDelegate> @property(nonatomic,strong) WKWebView *w; @property(nonatomic,copy) NSString *out; @property(nonatomic,copy) NSString *provider; @end
@implementation R
- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)n {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.6*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSString *profiles = @"window.setProfiles({"
          "claude:{name:'Claude Code',gears:{'1':{model:'Haiku 4.5'},'2':{model:'Sonnet 5'},'3':{model:'Opus 4.8'},"
            "'4':{model:'Fable 5',effort:'high'},'5':{model:'Fable 5',effort:'max'},'R':{model:'Default',effort:'auto'}},"
            "lever:{label:'ultracode',model:'Fable 5',effort:'ultracode'}},"
          "codex:{name:'Codex',gears:{'1':{model:'gpt-5.4-mini',effort:'medium'},'2':{model:'gpt-5.6-luna',effort:'medium'},"
            "'3':{model:'gpt-5.6-terra',effort:'medium'},'4':{model:'gpt-5.6-sol',effort:'high'},'5':{model:'gpt-5.6-sol',effort:'max'},"
            "'R':{model:'gpt-5.6-sol',effort:'low'}},lever:{label:'ultra',model:'gpt-5.6-sol',effort:'ultra'}}});";
        NSString *live = [self.provider isEqualToString:@"codex"]
          ? @"window.setLive({agent:'codex',model:'gpt-5.6-sol',token:'gpt-5.6-sol',effort:'high'});window.demoSelect('R','ultra');"
          : @"window.setLive({agent:'claude',model:'Fable 5',token:'fable',effort:'xhigh'});window.demoSelect('4','medium');";
        NSString *js = live; (void)profiles;
        [self.w evaluateJavaScript:js completionHandler:^(id r, NSError *e){
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                WKSnapshotConfiguration *cfg = [WKSnapshotConfiguration new];
                [self.w takeSnapshotWithConfiguration:cfg completionHandler:^(NSImage *img, NSError *err){
                    if (img) {
                        CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
                        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
                        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                        [png writeToFile:self.out atomically:YES];
                        printf("wrote %s (%lux%lu)\n", self.out.UTF8String, (unsigned long)CGImageGetWidth(cg), (unsigned long)CGImageGetHeight(cg));
                    } else printf("snapshot failed: %s\n", err.localizedDescription.UTF8String);
                    [NSApp terminate:nil];
                }];
            });
        }];
    });
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        R *r = [R new];
        r.out = argc>2 ? [NSString stringWithUTF8String:argv[2]] : @"/tmp/gearbox.png";
        r.provider = argc>3 ? [NSString stringWithUTF8String:argv[3]] : @"claude";
        NSString *htmlPath = argc>1 ? [NSString stringWithUTF8String:argv[1]] : @"src/app/gearbox.html";
        NSString *html = [NSString stringWithContentsOfFile:htmlPath encoding:NSUTF8StringEncoding error:nil];
        WKWebView *w = [[WKWebView alloc] initWithFrame:NSMakeRect(0,0,300,420)];
        r.w = w; w.navigationDelegate = r;
        [w setValue:@NO forKey:@"drawsBackground"];
        // Put it in a real on-screen window so the compositor advances CSS transitions
        // (offscreen WKWebViews don't repaint dynamic style/transition changes).
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(120,220,300,420)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        win.contentView = w; win.level = NSFloatingWindowLevel; win.opaque = NO;
        win.backgroundColor = [NSColor clearColor];
        [win orderFrontRegardless];
        [w loadHTMLString:html baseURL:nil];
        [app run];
    }
    return 0;
}
