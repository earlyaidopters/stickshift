#import "Switch.h"
#import "AXState.h"
#import "Inject.h"
#import "Manifest.h"
#import "Proc.h"
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <mach/mach_time.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <sys/file.h>

// Frame-age invariant (PLAN item 12): a batch must inject within this window of the
// fresh read it was validated against, else the frame is stale and we refuse.
static const double kMaxFrameAgeMs = 150.0;
static double msSince(uint64_t t0) {
    static mach_timebase_info_data_t tb; if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6;
}

// Privacy-safe log: state transitions + reason codes only, never pane text (PLAN 29/31).
void StickShiftLogLine(NSString *line) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@".stickshift"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@(0700)} error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"log"];
    // rotate at ~1MB
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([a fileSize] > 1024*1024) {
        [[NSFileManager defaultManager] removeItemAtPath:[path stringByAppendingString:@".1"] error:nil];
        [[NSFileManager defaultManager] moveItemAtPath:path toPath:[path stringByAppendingString:@".1"] error:nil];
    }
    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
        dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];
    NSString *entry = [NSString stringWithFormat:@"%@  %@\n", stamp, line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) { [entry writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    else { [fh seekToEndOfFile]; [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

// One OS-level interprocess lock for EVERY client (CLI and app), PLAN item 28. Held only
// across a commit's inject→verify. Returns fd>=0 on success, -1 on contention.
static int acquireSwitchLock(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@".stickshift"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@(0700)} error:nil];
    NSString *lock = [dir stringByAppendingPathComponent:@"lock"];
    int fd = open(lock.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return -1; }
    return fd;
}

@implementation SwitchOutcome
- (NSString *)describe {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@", ShiftReasonCode(self.reason)];
    if (self.stage.length) [s appendFormat:@" @%@", self.stage];
    if (self.detail.length) [s appendFormat:@" — %@", self.detail];
    return s;
}
@end

@implementation Switch

static SwitchOutcome *out(ShiftReason r, NSString *stage, NSString *detail) {
    SwitchOutcome *o = [SwitchOutcome new]; o.reason = r; o.stage = stage; o.detail = detail; return o;
}

+ (NSString *)bottomLines:(NSString *)txt count:(NSUInteger)n {
    if (!txt.length) return @"";
    NSArray *bl = [txt componentsSeparatedByString:@"\n"];
    NSUInteger bt = bl.count > n ? bl.count - n : 0;
    return [[bl subarrayWithRange:NSMakeRange(bt, bl.count - bt)] componentsJoinedByString:@"\n"];
}

+ (NSUInteger)occurrencesOf:(NSString *)needle inText:(NSString *)txt {
    if (!needle.length || !txt.length) return 0;
    NSUInteger c = 0;
    NSRange search = NSMakeRange(0, txt.length);
    while (search.length >= needle.length) {
        NSRange f = [txt rangeOfString:needle options:0 range:search];
        if (f.location == NSNotFound) break;
        c++;
        NSUInteger next = NSMaxRange(f);
        search = NSMakeRange(next, txt.length - next);
    }
    return c;
}

+ (BOOL)dialogTarget:(NSString *)target matchesExpected:(NSString *)expect {
    if (!target.length || !expect.length) return NO;
    if ([target caseInsensitiveCompare:expect] == NSOrderedSame) return YES;
    if (target.length > expect.length
        && [target compare:expect options:NSCaseInsensitiveSearch
                     range:NSMakeRange(0, expect.length)] == NSOrderedSame) {
        unichar next = [target characterAtIndex:expect.length];
        return next == ' ' || next == '(';   // "Opus 4.8 (1M context)" yes, "Opus 4.8.1" no
    }
    return NO;
}

// Pure no-op test: is the pane already at (model, effort)? A nil expectEffort means
// "don't care about effort" (model-only gear). Exposed for tests.
+ (BOOL)pane:(PaneState *)pane alreadyAtModel:(NSString *)expectModel effort:(NSString *)expectEffort {
    BOOL modelMatches = pane.modelText && [pane.modelText isEqualToString:expectModel];
    BOOL effortMatches = !expectEffort || (pane.effortText && [pane.effortText isEqualToString:expectEffort]);
    return modelMatches && effortMatches;
}

// Permission preflight: Accessibility is needed to read the pane; Post-Events to inject.
// Returns ShiftOK if sufficient for `commit`, else ShiftNoPermission.
+ (ShiftReason)permissionCheckForCommit:(BOOL)commit detail:(NSString **)detail {
    if (!AXIsProcessTrusted()) {
        if (detail) *detail = @"Accessibility permission not granted (System Settings → Privacy → Accessibility)";
        return ShiftNoPermission;
    }
    if (commit && !CGPreflightPostEventAccess()) {
        if (detail) *detail = @"Post-Events (keystroke) permission not granted";
        return ShiftNoPermission;
    }
    return ShiftOK;
}

+ (BOOL)revalidate:(TargetTuple *)t reason:(ShiftReason *)why { return [self revalidate:t reason:why readStart:NULL]; }

// Fresh AX pane re-read + identity revalidation against the fixed tuple (PLAN item 12).
// readStart (out) is stamped at the moment of the read so the caller can enforce the
// frame-age invariant before the first keystroke.
+ (BOOL)revalidate:(TargetTuple *)t reason:(ShiftReason *)why readStart:(uint64_t *)readStart {
    uint64_t t0 = mach_absolute_time();
    if (readStart) *readStart = t0;
    PaneState *fresh = [AXState readFocusedPaneForTerminal:t.terminalPid];
    if (!fresh.hasFocusedWindow) { *why = ShiftNoFocusedWindow; return NO; }
    if (fresh.agent != t.identity.kind) { *why = ShiftNoAgent; return NO; }
    // window title + geometry stability
    if (t.windowTitle && fresh.windowTitle && ![fresh.windowTitle isEqualToString:t.windowTitle]) {
        *why = ShiftAmbiguousWindow; return NO;
    }
    if (!CGRectEqualToRect(CGRectIntegral(fresh.focusedFrame), CGRectIntegral(t.geometry))) {
        *why = ShiftAmbiguousWindow; return NO;
    }
    // agent liveness + still foreground on same tty/start
    ProcTable *tbl = [ProcTable snapshot];
    ProcRow *row = [tbl rowForPid:t.agentPid];
    if (!row || row.startSec != t.agentStartSec) { *why = ShiftNoAgent; return NO; }
    // Keyboard-routing invariant: synthetic keystrokes go to the KEY window, which is
    // NOT necessarily in the frontmost app — a non-activating panel (ours!) can hold
    // key focus while the terminal stays frontmost. Injecting then types into the
    // panel and vanishes. Require the terminal to own the system-wide focused element.
    pid_t kfp = [AXState keyboardFocusPid];
    if (kfp != t.terminalPid) { *why = ShiftKeyFocusElsewhere; return NO; }
    return YES;
}

+ (SwitchOutcome *)runGear:(NSString *)gear
                    config:(Config *)cfg
               invokingTty:(NSString *)invokingTty
                    commit:(BOOL)commit
          terminalOverride:(pid_t)terminalOverride {
    NSString *pdetail = nil; ShiftReason perm = [self permissionCheckForCommit:commit detail:&pdetail];
    if (perm != ShiftOK) return out(perm, @"PRECHECK", pdetail);
    // RESOLVE_TARGET
    pid_t termPid = terminalOverride ?: [AXState frontmostPid];
    NSString *bundle = terminalOverride
        ? ([NSRunningApplication runningApplicationWithProcessIdentifier:termPid].bundleIdentifier ?: @"?")
        : [AXState frontmostBundleId];
    if (![cfg.enabledTerminals containsObject:bundle])
        return out(ShiftNotTerminal, @"RESOLVE_TARGET", ([NSString stringWithFormat:@"frontmost %@ not an enabled terminal", bundle]));

    // Secure input is global; check up front.
    if (IsSecureEventInputEnabled())
        return out(ShiftSecureInput, @"PRECHECK", @"secure keyboard entry is on");

    // ATTRIBUTE_PROCESS
    AttributionResult *ar = [Attribution attributeFocusedTerminal:termPid invokingTty:invokingTty];
    if (ar.reason != ShiftOK) return out(ar.reason, @"ATTRIBUTE_PROCESS", ar.detail);
    TargetTuple *t = ar.target;

    GearTuple *tuple = [cfg tupleForGear:gear kind:t.identity.kind];
    if (!tuple) return out(ShiftBadConfig, @"PRECHECK", ([NSString stringWithFormat:@"no tuple for gear %@", gear]));
    return [self applyTuple:tuple target:t cfg:cfg commit:commit];
}

// Switch to an EXPLICIT (model token, effort) chosen in the UI (stick + effort lever),
// rather than a fixed gear. Same pipeline; the agent kind comes from attribution.
+ (SwitchOutcome *)runModelToken:(NSString *)modelToken
                          effort:(NSString *)effort
                          config:(Config *)cfg
                     invokingTty:(NSString *)invokingTty
                          commit:(BOOL)commit
                terminalOverride:(pid_t)terminalOverride {
    NSString *pdetail = nil; ShiftReason perm = [self permissionCheckForCommit:commit detail:&pdetail];
    if (perm != ShiftOK) return out(perm, @"PRECHECK", pdetail);
    pid_t termPid = terminalOverride ?: [AXState frontmostPid];
    NSString *bundle = terminalOverride
        ? ([NSRunningApplication runningApplicationWithProcessIdentifier:termPid].bundleIdentifier ?: @"?")
        : [AXState frontmostBundleId];
    if (![cfg.enabledTerminals containsObject:bundle])
        return out(ShiftNotTerminal, @"RESOLVE_TARGET", ([NSString stringWithFormat:@"frontmost %@ not an enabled terminal", bundle]));
    if (IsSecureEventInputEnabled())
        return out(ShiftSecureInput, @"PRECHECK", @"secure keyboard entry is on");
    AttributionResult *ar = [Attribution attributeFocusedTerminal:termPid invokingTty:invokingTty];
    if (ar.reason != ShiftOK) return out(ar.reason, @"ATTRIBUTE_PROCESS", ar.detail);
    GearTuple *tuple = [GearTuple new];
    tuple.model = modelToken;
    tuple.effort = (effort.length ? effort : nil);
    return [self applyTuple:tuple target:ar.target cfg:cfg commit:commit];
}

// Shared post-attribution core: precheck, plan, no-op, inject, watch, verify.
+ (SwitchOutcome *)applyTuple:(GearTuple *)tuple target:(TargetTuple *)t cfg:(Config *)cfg commit:(BOOL)commit {
    // PRECHECK (fail closed)
    PaneState *pane = t.pane;
    if (pane.busy) return out(ShiftBusy, @"PRECHECK", @"agent is busy (esc-to-interrupt present)");
    if (pane.switchDialogOpen) return out(ShiftDialogOpen, @"PRECHECK", @"a switch dialog is already open");
    if (!pane.idle) return out(ShiftBusy, @"PRECHECK", @"no positive idle-prompt match");
    if (!pane.inputEmpty) return out(ShiftDraftPresent, @"PRECHECK", @"input box is not provably empty");

    if (![[Manifest shared] isTupleQualifiedForKind:t.identity.kind model:tuple.model effort:tuple.effort])
        return out(ShiftUnsupportedEffort, @"PRECHECK", @"(model,effort) not qualified for this agent");
    SwitchPlan *plan = [ShiftProtocol planForKind:t.identity.kind tuple:tuple currentModelDisplay:pane.modelText];
    if (!plan) return out(ShiftBadConfig, @"PRECHECK", @"could not build a qualified plan");

    // No-op check (ALREADY_SET): compare current pane model/effort to target.
    if ([self pane:pane alreadyAtModel:plan.expectedModelDisplay effort:plan.expectedEffort]) {
        SwitchOutcome *o = out(ShiftAlreadySet, @"PRECHECK", ([NSString stringWithFormat:@"already %@%@",
            plan.expectedModelDisplay, plan.expectedEffort?[@" / "stringByAppendingString:plan.expectedEffort]:@""]));
        o.target = t; o.plan = plan; return o;
    }

    if (!commit) {
        SwitchOutcome *o = out(ShiftOK, @"DRY_RUN", ([NSString stringWithFormat:@"would apply — %@", plan.summary]));
        o.target = t; o.plan = plan; o.committed = NO;
        return o;
    }

    // One interprocess lock for every client (CLI + app), held across inject→verify.
    int lockFd = acquireSwitchLock();
    if (lockFd < 0) { SwitchOutcome *o = out(ShiftLocked, @"INJECT", @"another StickShift switch is in progress");
        o.target = t; o.plan = plan; return o; }
    SwitchOutcome *result = [self injectAndVerify:plan target:t cfg:cfg];
    flock(lockFd, LOCK_UN); close(lockFd);
    return result;
}

+ (SwitchOutcome *)injectAndVerify:(SwitchPlan *)plan target:(TargetTuple *)t cfg:(Config *)cfg {
    // Snapshot the dialog policy for the WHOLE run: the settings drawer stays usable
    // during a switch, and a mid-flight change must not retarget an in-progress commit.
    BOOL autoAnswer = cfg.autoAnswerEnabled;
    DialogPolicy policy = cfg.dialogPolicy;
    // INJECT with per-batch revalidation.
    for (PlanStep *step in plan.steps) {
        if (step.kind == StepWaitState) {
            NSString *detail = nil;
            ShiftReason r = [self awaitStep:step target:t autoAnswer:autoAnswer policy:policy detail:&detail];
            if (r != ShiftOK) {
                SwitchOutcome *o = out(r, @"WATCH", detail ?: ([NSString stringWithFormat:@"did not observe '%@'", step.text]));
                o.target = t; o.plan = plan; return o;
            }
            continue;
        }
        ShiftReason why = ShiftOK; uint64_t readStart = 0;
        if (![self revalidate:t reason:&why readStart:&readStart]) {
            SwitchOutcome *o = out(why, @"INJECT",
                why == ShiftKeyFocusElsewhere
                    ? @"keyboard focus is not on the terminal — click the target pane and retry"
                    : @"revalidation failed before batch");
            o.target = t; o.plan = plan; return o;
        }
        if (msSince(readStart) > kMaxFrameAgeMs) {
            SwitchOutcome *o = out(ShiftStaleFrame, @"INJECT",
                ([NSString stringWithFormat:@"frame %.0fms old (>%.0fms) — refusing to inject on a stale read",
                  msSince(readStart), kMaxFrameAgeMs]));
            o.target = t; o.plan = plan; return o;
        }
        if (step.kind == StepCodexSelect) {
            // Read the live picker; press the row that actually shows this label.
            PaneState *pk = [AXState readFocusedPaneForTerminal:t.terminalPid];
            NSInteger row = [AXState codexPickerRowFor:step.text inText:pk.paneText];
            if (row <= 0) {
                SwitchOutcome *o = out(ShiftBadConfig, @"INJECT", ([NSString stringWithFormat:@"'%@' not offered in the codex picker", step.text]));
                o.target = t; o.plan = plan; return o;
            }
            if (row > 9) {   // pressDigit is a single keystroke; a 2-digit row would mis-select
                SwitchOutcome *o = out(ShiftBadConfig, @"INJECT", ([NSString stringWithFormat:@"picker row %ld exceeds single-digit selection", (long)row]));
                o.target = t; o.plan = plan; return o;
            }
            [Inject pressDigit:(int)row];
            usleep(120000);
            continue;
        }
        switch (step.kind) {
            case StepTypeText: {
                if (![Inject canTypeText:step.text]) {
                    SwitchOutcome *o = out(ShiftInjectDropped, @"INJECT",
                        ([NSString stringWithFormat:@"'%@' contains a character the current keyboard layout cannot type", step.text]));
                    o.target = t; o.plan = plan; return o;
                }
                // Delivery check (fail closed): the typed command must appear as a NEW
                // occurrence before any Return. Counting against a pre-type baseline
                // means the same command sitting in scrollback (a previous attempt in
                // this pane) can never fake delivery. Warp silently ignored the old
                // unicode event transport — a blind Enter after undelivered text
                // surfaces as a misleading UNKNOWN_FINAL_STATE minutes later.
                NSUInteger before = [self occurrencesOf:step.text
                    inText:[AXState readFocusedPaneForTerminal:t.terminalPid].paneText];
                [Inject typeText:step.text];
                BOOL landed = NO;
                for (int i = 0; i < 8 && !landed; i++) {
                    usleep(150000);
                    PaneState *pv = [AXState readFocusedPaneForTerminal:t.terminalPid];
                    landed = [self occurrencesOf:step.text inText:pv.paneText] > before;
                }
                if (!landed) {
                    SwitchOutcome *o = out(ShiftInjectDropped, @"INJECT",
                        ([NSString stringWithFormat:@"typed '%@' but it never appeared in the pane — the terminal dropped the synthetic keystrokes", step.text]));
                    o.target = t; o.plan = plan; return o;
                }
                break;
            }
            case StepReturn:   [Inject pressReturn]; break;
            case StepEscape:   [Inject pressEscape]; break;
            case StepDown:     [Inject pressDown]; break;
            case StepUp:       [Inject pressUp]; break;
            case StepDigit:    [Inject pressDigit:step.digit]; break;
            default: break;
        }
        usleep(120000); // settle before next revalidation
    }

    // WATCH for dialog vs target state
    SwitchOutcome *watch = [self watchAfterInject:t plan:plan autoAnswer:autoAnswer policy:policy];
    watch.target = t; watch.plan = plan; watch.committed = YES;
    return watch;
}

+ (BOOL)waitFor:(NSString *)needle target:(TargetTuple *)t timeout:(NSTimeInterval)to {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:to];
    while ([deadline timeIntervalSinceNow] > 0) {
        PaneState *p = [AXState readFocusedPaneForTerminal:t.terminalPid];
        if ([p.paneText containsString:needle]) return YES;
        usleep(200000);
    }
    return NO;
}

// Wait for a plan step's result. For Claude model/effort steps we verify against the
// pane's CLASSIFIED status line (the authoritative post-switch signal — it always shows
// the current model/effort, direct or after the dialog), and handle the mid-conversation
// "Switch model?" dialog (the gear-pull is the user's confirmation). Codex picker steps
// have no such dialog and just wait for their string needle.
+ (StepDecision)decideStep:(PlanStep *)step pane:(PaneState *)p
                 autoAnswer:(BOOL)autoAnswer policy:(DialogPolicy)policy confirmed:(BOOL)confirmed {
    NSString *txt = p.paneText ?: @"";
    // Everything below matches against the BOTTOM of the pane only: the full AX value
    // includes scrollback, where an old "not found", stale confirmation line, or a
    // previous run of this same command would turn history into a current verdict.
    NSString *bottom = [self bottomLines:txt count:12];
    // Errors first — the agent prints them directly above the composer.
    if (step.expectModel && [bottom containsString:@"Model '"] && [bottom containsString:@"' not found"]) return StepDecError;
    if (step.expectEffort && [bottom containsString:@"Invalid argument"]) return StepDecError;
    // Success via classified status line (only when no dialog is open, so the dialog body
    // naming the target model can't be a false positive).
    if (step.expectModel && !p.switchDialogOpen && [p.modelText isEqualToString:step.expectModel]) return StepDecMatched;
    if (step.expectEffort) {
        if ([p.effortText isEqualToString:step.expectEffort]) return StepDecMatched;   // the ◉/○ chip
        if ([bottom containsString:[@"Set effort level to " stringByAppendingString:step.expectEffort]]) return StepDecMatched;
    }
    if (!step.expectModel && !step.expectEffort
        && [[self bottomLines:txt count:16] containsString:step.text]) return StepDecMatched;
    // The switch-confirm dialog. Only answer OUR dialog: the extracted target must
    // equal this step's expectation — a dialog raised by anything else (user typing,
    // a delayed earlier command) is left alone regardless of policy.
    if (step.handlesDialog && p.switchDialogOpen && !confirmed) {
        NSString *expect = step.expectModel ?: step.expectEffort;
        BOOL ours = [self dialogTarget:p.dialogTargetDisplay matchesExpected:expect];
        if (!ours) return StepDecDialogOpen;
        if (!autoAnswer || policy == DialogAsk) return StepDecDialogOpen;
        if (policy == DialogCancel) return StepDecCancel;
        return StepDecConfirm;
    }
    return StepDecWait;
}

+ (ShiftReason)awaitStep:(PlanStep *)step target:(TargetTuple *)t
              autoAnswer:(BOOL)autoAnswer policy:(DialogPolicy)policy detail:(NSString **)detail {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    BOOL confirmed = NO;
    while ([deadline timeIntervalSinceNow] > 0) {
        PaneState *p = [AXState readFocusedPaneForTerminal:t.terminalPid];
        StepDecision d = [self decideStep:step pane:p autoAnswer:autoAnswer policy:policy confirmed:confirmed];
        switch (d) {
            case StepDecMatched: return ShiftOK;
            case StepDecError:
                if (detail) *detail = step.expectEffort ? @"invalid effort" : @"model not found";
                return step.expectEffort ? ShiftUnsupportedEffort : ShiftBadConfig;
            case StepDecDialogOpen:
                if (detail) *detail = @"Claude asked to confirm the switch; confirm in the terminal or enable auto-confirm";
                return ShiftDialogOpen;
            case StepDecCancel: { [Inject pressDigit:2]; if (detail) *detail = @"cancelled per policy"; return ShiftUnchanged; }
            case StepDecConfirm: {
                ShiftReason why = ShiftOK; uint64_t rs = 0;
                if (![self revalidate:t reason:&why readStart:&rs]) { if (detail) *detail = @"revalidation failed before confirming dialog"; return why; }
                if (msSince(rs) > kMaxFrameAgeMs) { if (detail) *detail = @"stale frame before confirming dialog"; return ShiftStaleFrame; }
                [Inject pressReturn];   // "Yes, switch" is the highlighted default; Enter confirms
                confirmed = YES;
                usleep(300000);
                continue;
            }
            case StepDecWait: default: break;
        }
        usleep(180000);
    }
    if (detail) *detail = step.expectModel ? [NSString stringWithFormat:@"model did not become %@", step.expectModel]
                       : (step.expectEffort ? [NSString stringWithFormat:@"effort did not become %@", step.expectEffort]
                       : [NSString stringWithFormat:@"did not observe '%@'", step.text]);
    return ShiftUnknownFinalState;
}

+ (SwitchOutcome *)watchAfterInject:(TargetTuple *)t plan:(SwitchPlan *)plan
                         autoAnswer:(BOOL)autoAnswer policy:(DialogPolicy)policy {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.5];
    while ([deadline timeIntervalSinceNow] > 0) {
        PaneState *p = [AXState readFocusedPaneForTerminal:t.terminalPid];
        if (p.switchDialogOpen) {
            // Only answer OUR dialog: the extracted target must match this plan's
            // expected model or effort. A dialog raised by anything else (user typing,
            // a delayed earlier command) is never keyed — not even to cancel it.
            BOOL ours = [self dialogTarget:p.dialogTargetDisplay matchesExpected:plan.expectedModelDisplay]
                     || [self dialogTarget:p.dialogTargetDisplay matchesExpected:plan.expectedEffort];
            if (!ours)
                return out(ShiftDialogOpen, @"WATCH", @"a switch dialog is open but it is not ours — not answering it");
            if (!autoAnswer || policy == DialogAsk)
                return out(ShiftDialogOpen, @"WATCH", @"switch dialog open; policy=ask (user decides)");
            // auto policy: revalidate (fresh frame) then answer
            ShiftReason why = ShiftOK; uint64_t rs = 0;
            if (![self revalidate:t reason:&why readStart:&rs]) return out(why, @"WATCH", @"revalidation failed before answering dialog");
            if (msSince(rs) > kMaxFrameAgeMs) return out(ShiftStaleFrame, @"WATCH", @"stale frame before answering dialog");
            if (policy == DialogConfirm) [Inject pressDigit:1];
            else { [Inject pressDigit:2]; return out(ShiftUnchanged, @"WATCH", @"dialog cancelled per policy"); }
        }
        NSString *bottom = [self bottomLines:p.paneText count:16];
        for (NSString *needle in plan.evidenceNeedles)
            if ([bottom containsString:needle])
                return out(ShiftChanged, @"VERIFY", ([NSString stringWithFormat:@"evidence: %@", needle]));
        usleep(200000);
    }
    return out(ShiftUnknownFinalState, @"VERIFY", @"no evidence signal by deadline; no retry until fresh status");
}

@end
