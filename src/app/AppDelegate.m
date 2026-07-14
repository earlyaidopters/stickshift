#import "AppDelegate.h"
#import <WebKit/WebKit.h>
#import <Carbon/Carbon.h>
#import "Config.h"
#import "AXState.h"
#import "Switch.h"
#import "Protocol.h"
#import "Attribution.h"
#import "Reason.h"

// The gearbox is mouse-only. If the panel ever becomes KEY, macOS routes keyboard —
// including our synthetic keystrokes — into the panel's WebView instead of the
// terminal (non-activating panels take key focus on click without activating the
// app; Warp stays frontmost, so every precheck passes and the keys just vanish).
// This was the live failure at 2026-07-13 09:59: the first lever click after launch
// silently ate every subsequent shift, hotkeys included.
@interface GearboxPanel : NSPanel @end
@implementation GearboxPanel
- (BOOL)canBecomeKeyWindow { return NO; }
@end

@interface AppDelegate () <WKScriptMessageHandler, NSWindowDelegate, WKNavigationDelegate>
@property(nonatomic,strong) NSStatusItem *statusItem;
@property(nonatomic,strong) NSPanel *panel;
@property(nonatomic,strong) WKWebView *web;
@property(nonatomic,strong) Config *cfg;
@property(nonatomic,strong) NSTimer *stateTimer;
@property(nonatomic,strong) NSArray<NSString*> *hotkeyGears;
@property(nonatomic) BOOL busy;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    // Ask for Accessibility OURSELVES when untrusted: the system prompt registers the
    // TCC row against THIS binary's designated requirement. Rows added manually via
    // "+" (or inherited from an older signature) can point at stale requirements and
    // show an enabled toggle that grants nothing — that burned three re-grants today.
    if (!AXIsProcessTrusted()) {
        NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
        StickShiftLogLine(@"launch: not AX-trusted — requested the system Accessibility prompt");
    }
    self.cfg = [Config load];
    // In the app, pulling a gear IS the user's confirmation, so auto-confirm Claude's
    // benign "Switch model?" dialog (unless the user set cancel/ask in their config).
    // A MALFORMED config must not fall through to these first-run defaults: a file the
    // user wrote but we rejected (symlink, wrong owner, unreadable) silently enabling
    // auto-confirm is exactly the wrong failure mode. Refuse shifts instead.
    if (!self.cfg.loadedFromFile && !self.cfg.malformed) { self.cfg.autoAnswerEnabled = YES; self.cfg.dialogPolicy = DialogConfirm; }
    if (self.cfg.malformed)
        StickShiftLogLine([NSString stringWithFormat:@"config rejected: %@ — shifts disabled until fixed",
            self.cfg.loadError ?: @"malformed"]);

    // menu-bar item
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"⚙";
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusClicked:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];

    [self buildPanel];
    [self registerHotkeys];
    // refresh live state while visible
    self.stateTimer = [NSTimer scheduledTimerWithTimeInterval:1.2 target:self
        selector:@selector(pushState) userInfo:nil repeats:YES];
    // Show the gearbox on launch. As an LSUIElement app the ⚙ menu-bar item is the
    // only other visible surface — launching with no window reads as "didn't open".
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSRect scr = NSScreen.mainScreen.frame;
        NSRect pf = self.panel.frame;
        [self.panel setFrameOrigin:NSMakePoint(NSMidX(scr) - pf.size.width/2,
                                               NSMaxY(scr) - pf.size.height - 80)];
        [self.panel orderFrontRegardless];
        [self pushState];
    });
}

// Double-clicking the app while it is already running arrives as a reopen event
// (there is no Dock icon or window to click). Bring the gearbox up instead of
// silently ignoring it — without this, relaunching looks like the app is broken.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {
    if (!self.panel.isVisible) [self togglePanel:nil];
    else [self.panel orderFrontRegardless];
    return NO;
}

- (void)buildPanel {
    NSRect frame = NSMakeRect(0, 0, 760, 440);
    self.panel = [[GearboxPanel alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskNonactivatingPanel|NSWindowStyleMaskTitled|
                   NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|
                   NSWindowStyleMaskUtilityWindow|NSWindowStyleMaskFullSizeContentView)
        backing:NSBackingStoreBuffered defer:NO];
    self.panel.title = @"StickShift";
    self.panel.titlebarAppearsTransparent = YES;
    self.panel.titleVisibility = NSWindowTitleHidden;
    self.panel.floatingPanel = YES;
    self.panel.becomesKeyOnlyIfNeeded = YES;
    self.panel.hidesOnDeactivate = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.movableByWindowBackground = YES;
    self.panel.delegate = self;

    WKWebViewConfiguration *c = [WKWebViewConfiguration new];
    [c.userContentController addScriptMessageHandler:self name:@"shift"];
    [c.userContentController addScriptMessageHandler:self name:@"drag"];
    [c.userContentController addScriptMessageHandler:self name:@"resize"];
    [c.userContentController addScriptMessageHandler:self name:@"policy"];
    self.web = [[WKWebView alloc] initWithFrame:frame configuration:c];
    self.web.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    self.web.navigationDelegate = self;
    [self.web setValue:@NO forKey:@"drawsBackground"];
    self.panel.contentView = self.web;

    NSString *html = [self loadGearboxHTML];
    [self.web loadHTMLString:html baseURL:nil];
}

- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)n {
    [self pushProfiles];   // static per-provider labels (exact model + effort names)
    [self pushState];      // live focused-pane state
    [self pushPolicy];     // current switch-dialog policy for the settings drawer
}

- (void)pushPolicy {
    NSString *p = !self.cfg.autoAnswerEnabled ? @"ask"
                : (self.cfg.dialogPolicy == DialogConfirm ? @"confirm"
                : (self.cfg.dialogPolicy == DialogCancel ? @"cancel" : @"ask"));
    [self.web evaluateJavaScript:[NSString stringWithFormat:@"window.setPolicy('%@')", p]
               completionHandler:nil];
}

- (NSString *)loadGearboxHTML {
    NSString *exeDir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
    NSMutableArray *paths = [NSMutableArray array];
    NSString *bundled = [[NSBundle mainBundle] pathForResource:@"gearbox" ofType:@"html"];
    if (bundled) [paths addObject:bundled];                                    // StickShift.app/Contents/Resources
    [paths addObject:[exeDir stringByAppendingPathComponent:@"gearbox.html"]]; // bare bin/ build
    [paths addObject:[exeDir stringByAppendingPathComponent:@"../src/app/gearbox.html"]]; // dev tree
    for (NSString *p in paths) {
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (s) return s;
    }
    return @"<body style='color:#fff;background:#111;font-family:sans-serif;padding:20px'>gearbox.html not found</body>";
}

// Left click toggles the gearbox; right click gets the housekeeping menu (as a
// standalone .app there is no terminal to Ctrl-C, so Quit must live somewhere).
- (void)statusClicked:(id)sender {
    if ([NSApp currentEvent].type == NSEventTypeRightMouseUp) {
        NSMenu *m = [NSMenu new];
        [m addItemWithTitle:@"Show / Hide Gearbox" action:@selector(togglePanel:) keyEquivalent:@""].target = self;
        [m addItem:[NSMenuItem separatorItem]];
        [m addItemWithTitle:@"Quit StickShift" action:@selector(terminate:) keyEquivalent:@"q"];
        [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:self.statusItem.button];
        return;
    }
    [self togglePanel:sender];
}

- (void)togglePanel:(id)sender {
    if (self.panel.isVisible) { [self.panel orderOut:nil]; return; }
    // place near the status item
    NSRect sb = self.statusItem.button.window.frame;
    NSRect pf = self.panel.frame;
    NSPoint origin = NSMakePoint(NSMaxX(sb) - pf.size.width, NSMinY(sb) - pf.size.height - 6);
    [self.panel setFrameOrigin:origin];
    [self.panel orderFrontRegardless];   // non-activating: terminal keeps focus
    [self pushState];
}

// Provider-EXACT effort display. Claude: as-is (low..ultracode). Codex: xhigh->extra high.
- (NSString *)uiEffortForKind:(AgentKind)kind token:(NSString *)token {
    if (!token.length) return @"";
    if (kind == AgentCodex && [token isEqualToString:@"xhigh"]) return @"extra high";
    return token;
}

// Static per-provider model list (gate order) + every effort level per model, from the
// spike-7/8 vocabularies. Each entry carries a display label AND the internal token the
// injector uses.
- (NSString *)profileJSONForKind:(AgentKind)kind name:(NSString *)name {
    // models in gate order: 1,2,3,4,5,R (empty slots allowed)
    NSArray *models = kind == AgentClaude
      ? @[@[@"haiku",@"Haiku 4.5"], @[@"sonnet",@"Sonnet 5"], @[@"default",@"Opus 4.8"], @[@"fable",@"Fable 5"]]
      : @[@[@"gpt-5.4-mini",@"gpt-5.4-mini"], @[@"gpt-5.4",@"gpt-5.4"], @[@"gpt-5.5",@"gpt-5.5"],
          @[@"gpt-5.6-luna",@"gpt-5.6-luna"], @[@"gpt-5.6-terra",@"gpt-5.6-terra"], @[@"gpt-5.6-sol",@"gpt-5.6-sol"]];
    NSArray *gates = @[@"1",@"2",@"3",@"4",@"5",@"R"];
    NSMutableString *mjson = [NSMutableString stringWithString:@"["];
    for (NSUInteger i = 0; i < models.count && i < gates.count; i++) {
        [mjson appendFormat:@"{gate:'%@',token:'%@',label:'%@'},", gates[i],
            [self jsEsc:models[i][0]], [self jsEsc:models[i][1]]];
    }
    [mjson appendString:@"]"];

    // efforts: token + provider-exact label. Codex tops out at 'ultra' only on models
    // that expose it (spike 7: sol has Ultra, luna does not).
    NSArray *effTokens = kind == AgentClaude
      ? @[@"low",@"medium",@"high",@"xhigh",@"max",@"ultracode"]
      : @[@"low",@"medium",@"high",@"xhigh",@"max"]; // base codex set (xhigh renders 'extra high')
    NSMutableString *ejson = [NSMutableString stringWithString:@"["];
    for (NSString *tk in effTokens)
        [ejson appendFormat:@"{token:'%@',label:'%@'},", tk, [self jsEsc:[self uiEffortForKind:kind token:tk]]];
    [ejson appendString:@"]"];
    // per-model effort overrides (codex sol gains 'ultra')
    NSString *overrides = kind == AgentCodex
      ? @"{'gpt-5.6-sol':[{token:'low',label:'low'},{token:'medium',label:'medium'},{token:'high',label:'high'},{token:'xhigh',label:'extra high'},{token:'max',label:'max'},{token:'ultra',label:'ultra'}]}"
      : @"{}";

    return [NSString stringWithFormat:@"{name:'%@',models:%@,efforts:%@,modelEfforts:%@}",
            [self jsEsc:name], mjson, ejson, overrides];
}

- (void)pushProfiles {
    NSString *js = [NSString stringWithFormat:@"window.setProfiles({claude:%@,codex:%@})",
        [self profileJSONForKind:AgentClaude name:@"Claude Code"],
        [self profileJSONForKind:AgentCodex name:@"Codex"]];
    [self.web evaluateJavaScript:js completionHandler:nil];
}

// live state -> UI
- (void)pushState {
    if (!self.panel.isVisible || self.busy) return;
    pid_t term = [AXState frontmostPid];
    NSString *bundle = [AXState frontmostBundleId];
    NSString *js;
    if (![self.cfg.enabledTerminals containsObject:bundle]) {
        js = @"window.setLive({agent:'',model:'',effort:''})";
    } else {
        PaneState *p = [AXState readFocusedPaneForTerminal:term];
        NSString *agent = p.agent==AgentClaude?@"claude":(p.agent==AgentCodex?@"codex":@"");
        NSString *effDisp = [self uiEffortForKind:p.agent token:p.effortText?:@""];
        NSString *token = [self modelTokenForKind:p.agent display:p.modelText];
        js = [NSString stringWithFormat:@"window.setLive({agent:'%@',model:'%@',token:'%@',effort:'%@'})",
            [self jsEsc:agent], [self jsEsc:p.modelText?:@""], [self jsEsc:token], [self jsEsc:effDisp]];
    }
    [self.web evaluateJavaScript:js completionHandler:nil];
}

// Reverse-map a detected model display name back to its injectable token.
- (NSString *)modelTokenForKind:(AgentKind)kind display:(NSString *)display {
    if (kind != AgentClaude) return display ?: @"";     // codex: display == token
    if (!display) return @"";
    if ([display hasPrefix:@"Haiku"]) return @"haiku";
    if ([display hasPrefix:@"Sonnet"]) return @"sonnet";
    if ([display hasPrefix:@"Fable"]) return @"fable";
    if ([display hasPrefix:@"Opus"]) return @"default";
    return @"";
}

- (NSString *)jsEsc:(NSString *)s {
    return [[s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
}

// shift request from JS: {model:'<token>', effort:'<token>'|'', gate:'<n>'}
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)msg {
    // Drag the panel: the WKWebView covers the whole window, so background mousedowns
    // don't reach it. The HTML posts "drag" on empty areas; start a native window drag
    // from the event currently being handled.
    if ([msg.name isEqualToString:@"drag"]) {
        NSEvent *ev = [NSApp currentEvent];
        if (ev) [self.panel performWindowDragWithEvent:ev];
        return;
    }
    // Switch-dialog policy from the settings drawer: apply live + persist to config.toml.
    if ([msg.name isEqualToString:@"policy"]) {
        NSString *p = [msg.body[@"policy"] isKindOfClass:[NSString class]] ? msg.body[@"policy"] : @"ask";
        if ([p isEqualToString:@"confirm"])     { self.cfg.dialogPolicy = DialogConfirm; self.cfg.autoAnswerEnabled = YES; }
        else if ([p isEqualToString:@"cancel"]) { self.cfg.dialogPolicy = DialogCancel;  self.cfg.autoAnswerEnabled = YES; }
        else                                    { self.cfg.dialogPolicy = DialogAsk;     self.cfg.autoAnswerEnabled = NO;  }
        NSString *perr = nil;
        BOOL ok = [self.cfg persistPolicy:&perr];
        NSString *js = [NSString stringWithFormat:@"window.policySaved({policy:'%@',ok:%@,err:'%@'})",
            [self jsEsc:p], ok ? @"true" : @"false", [self jsEsc:perr ?: @""]];
        [self.web evaluateJavaScript:js completionHandler:nil];
        return;
    }
    // Collapse/expand the panel height, anchored at the top edge so it grows downward.
    if ([msg.name isEqualToString:@"resize"]) {
        BOOL toCompact = [msg.body[@"compact"] boolValue];
        NSRect f = self.panel.frame;
        CGFloat top = NSMaxY(f);
        CGFloat newH = toCompact ? 58 : 440;
        f.size.height = newH; f.origin.y = top - newH;
        [self.panel setFrame:f display:YES animate:YES];
        return;
    }
    NSString *model = msg.body[@"model"];
    NSString *effort = msg.body[@"effort"];
    NSString *gate = msg.body[@"gate"] ?: @"";
    if (!model.length) return;
    if (self.cfg.malformed) {
        StickShiftLogLine([NSString stringWithFormat:@"ui model=%@ -> BAD_CONFIG — config rejected: %@",
            model, self.cfg.loadError ?: @"malformed"]);
        NSString *js = [NSString stringWithFormat:
            @"window.outcome({reason:'BAD_CONFIG',detail:'config.toml rejected (%@) — fix or delete it',ok:false,warn:false,activeGate:''})",
            [self jsEsc:self.cfg.loadError ?: @"malformed"]];
        [self.web evaluateJavaScript:js completionHandler:nil];
        return;
    }
    self.busy = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SwitchOutcome *o = [Switch runModelToken:model effort:effort config:self.cfg
                               invokingTty:nil commit:YES terminalOverride:0];
        StickShiftLogLine([NSString stringWithFormat:@"ui model=%@ effort=%@ -> %@",
            model, effort.length ? effort : @"-", [o describe]]);
        BOOL ok = (o.reason==ShiftChanged || o.reason==ShiftAlreadySet);
        BOOL warn = (o.reason==ShiftDialogOpen || o.reason==ShiftUnknownFinalState || o.reason==ShiftOK);
        NSString *js = [NSString stringWithFormat:@"window.outcome({reason:'%@',detail:'%@',ok:%@,warn:%@,activeGate:'%@'})",
            [self jsEsc:ShiftReasonCode(o.reason)], [self jsEsc:o.detail?:@""],
            ok?@"true":@"false", warn?@"true":@"false", ok?gate:@""];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.web evaluateJavaScript:js completionHandler:nil];
            self.busy = NO;
        });
    });
}

// ---- global hotkeys: Cmd+Shift+1..5 and Cmd+Shift+R ----
static OSStatus hotkeyHandler(EventHandlerCallRef ref, EventRef ev, void *ud);
- (void)registerHotkeys {
    EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallApplicationEventHandler(&hotkeyHandler, 1, &spec, (__bridge void *)self, NULL);
    struct { UInt32 code; NSString *gear; } keys[] = {
        {kVK_ANSI_1,@"1"},{kVK_ANSI_2,@"2"},{kVK_ANSI_3,@"3"},
        {kVK_ANSI_4,@"4"},{kVK_ANSI_5,@"5"},{kVK_ANSI_R,@"R"}
    };
    for (int i=0;i<6;i++){
        EventHotKeyID hid = { 'SHFT', (UInt32)i };
        EventHotKeyRef ref;
        RegisterEventHotKey(keys[i].code, cmdKey|shiftKey, hid, GetApplicationEventTarget(), 0, &ref);
    }
    self.hotkeyGears = @[@"1",@"2",@"3",@"4",@"5",@"R"];
}
- (void)fireGear:(NSString *)gear {
    if (self.cfg.malformed) {
        StickShiftLogLine([NSString stringWithFormat:@"hotkey gear=%@ -> BAD_CONFIG — config rejected: %@",
            gear, self.cfg.loadError ?: @"malformed"]);
        return;
    }
    self.busy = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SwitchOutcome *o = [Switch runGear:gear config:self.cfg invokingTty:nil commit:YES terminalOverride:0];
        StickShiftLogLine([NSString stringWithFormat:@"hotkey gear=%@ -> %@", gear, [o describe]]);
        dispatch_async(dispatch_get_main_queue(), ^{ self.busy=NO; NSLog(@"hotkey %@ -> %@", gear, [o describe]); });
    });
}
@end

static OSStatus hotkeyHandler(EventHandlerCallRef ref, EventRef ev, void *ud) {
    EventHotKeyID hid; GetEventParameter(ev, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hid), NULL, &hid);
    AppDelegate *self_ = (__bridge AppDelegate *)ud;
    NSArray *gears = self_.hotkeyGears;
    if (hid.id < gears.count) [self_ fireGear:gears[hid.id]];
    return noErr;
}
