#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Carbon/Carbon.h>
#import <sys/file.h>
#import <unistd.h>
#import "Reason.h"
#import "Config.h"
#import "AXState.h"
#import "Attribution.h"
#import "Switch.h"
#import "Proc.h"

// Privacy-safe logging lives in StickShiftLogLine (Switch.m), shared with the app.

static NSString *invokingTty(void) {
    char *t = ttyname(STDIN_FILENO);
    if (!t) t = ttyname(STDOUT_FILENO);
    return t ? [NSString stringWithUTF8String:t] : nil;
}

// --dwell: wait up to `secs` for an enabled-terminal agent pane to be stably focused
// (500ms), so a shell-invoked switch can target a pane the user clicks into afterward
// (the invoking pane itself SELF_TARGET-refuses downstream). Returns YES when ready.
static BOOL waitForDwell(Config *cfg, double secs) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:secs];
    NSString *stableKey = nil; NSDate *since = nil;
    fprintf(stderr, "dwell: focus the agent pane to shift (%.0fs)…\n", secs);
    while ([deadline timeIntervalSinceNow] > 0) {
        pid_t fp = [AXState frontmostPid];
        NSString *bundle = [AXState frontmostBundleId];
        if ([cfg.enabledTerminals containsObject:bundle]) {
            PaneState *p = [AXState readFocusedPaneForTerminal:fp];
            if (p.hasFocusedWindow && p.agent != AgentUnknown) {
                NSString *key = [NSString stringWithFormat:@"%d|%@", fp, p.windowTitle ?: @""];
                if ([key isEqualToString:stableKey]) {
                    if (since && -[since timeIntervalSinceNow] >= 0.5) return YES;
                } else { stableKey = key; since = [NSDate date]; }
            } else { stableKey = nil; since = nil; }
        } else { stableKey = nil; since = nil; }
        usleep(100000);
    }
    return NO;
}

static void printPreflight(void) {
    printf("  Accessibility (AX trusted) : %s\n", AXIsProcessTrusted() ? "yes" : "NO");
    printf("  Post events (CGEvent)      : %s\n", CGPreflightPostEventAccess() ? "yes" : "NO");
    printf("  Screen recording           : %s\n", CGPreflightScreenCaptureAccess() ? "yes" : "NO");
    printf("  Secure keyboard entry      : %s\n", IsSecureEventInputEnabled() ? "ON (blocks injection)" : "off");
}

static pid_t overridePid(NSArray<NSString*> *args) {
    NSUInteger i = [args indexOfObject:@"--pid"];
    if (i != NSNotFound && i + 1 < args.count) return (pid_t)[args[i+1] intValue];
    return 0;
}

static int cmdStatus(Config *cfg, pid_t override) {
    pid_t term = override ?: [AXState frontmostPid];
    NSString *bundle = override ? ([NSRunningApplication runningApplicationWithProcessIdentifier:term].bundleIdentifier ?: @"?")
                                : [AXState frontmostBundleId];
    PaneState *p = [AXState readFocusedPaneForTerminal:term];
    printf("focused terminal : %s (pid %d)\n", bundle.UTF8String, term);
    if (![cfg.enabledTerminals containsObject:bundle]) { printf("status           : NOT_TERMINAL (not enabled)\n"); return 0; }
    if (!p.hasFocusedWindow) { printf("status           : NO_FOCUSED_WINDOW\n"); return 0; }
    const char *kind = p.agent==AgentClaude?"claude":(p.agent==AgentCodex?"codex":"unknown");
    printf("agent            : %s\n", kind);
    printf("model            : %s\n", p.modelText.UTF8String ?: "(unknown)");
    printf("effort           : %s\n", p.effortText.UTF8String ?: "(unknown)");
    printf("cwd hint         : %s\n", p.cwdHint.UTF8String ?: "(none)");
    printf("state            : %s%s%s\n", p.idle?"idle":"", p.busy?"busy":"", p.switchDialogOpen?" dialog-open":"");
    printf("input            : %s\n", p.inputEmpty?"empty":"draft-present-or-unknown");
    if (p.agent == AgentUnknown) printf("note             : UNVERIFIABLE (no agent chrome detected)\n");
    return 0;
}

static int cmdDoctor(Config *cfg, pid_t override) {
    printf("StickShift doctor\n=================\n");
    printf("Permissions:\n"); printPreflight();
    printf("\nConfig:\n");
    printf("  path        : %s\n", [Config configPath].UTF8String);
    printf("  loaded      : %s\n", cfg.loadedFromFile ? "from file" : "built-in defaults");
    if (cfg.malformed) printf("  WARNING     : %s (mutating commands will refuse BAD_CONFIG)\n", cfg.loadError.UTF8String);
    const char *polName = cfg.dialogPolicy == DialogConfirm ? "confirm"
                        : (cfg.dialogPolicy == DialogCancel ? "cancel" : "ask");
    printf("  dialogPolicy: %s  autoAnswer: %s\n", polName, cfg.autoAnswerEnabled?"on":"off");
    printf("  terminals   : %s\n", [cfg.enabledTerminals componentsJoinedByString:@", "].UTF8String);

    // The app bundle + its signing identity: the TCC grant is keyed to this. An
    // ad-hoc signature here explains every "toggle is on but NO_PERMISSION" report.
    printf("\nApp:\n");
    NSString *appPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/StickShift.app"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:appPath]) {
        printf("  installed   : NO (~/Applications/StickShift.app missing — run make install-app)\n");
    } else {
        printf("  installed   : yes\n");
        NSTask *cs = [NSTask new]; cs.launchPath = @"/usr/bin/codesign";
        cs.arguments = @[@"-dvv", appPath];
        NSPipe *pe = [NSPipe pipe]; cs.standardError = pe; cs.standardOutput = [NSPipe pipe];
        @try { [cs launch]; [cs waitUntilExit]; } @catch (NSException *e) {}
        NSString *csOut = [[NSString alloc] initWithData:[pe.fileHandleForReading readDataToEndOfFile]
                                                encoding:NSUTF8StringEncoding] ?: @"";
        if ([csOut containsString:@"Authority=StickShift Dev"])
            printf("  signature   : StickShift Dev (stable — Accessibility grant survives reinstalls)\n");
        else if ([csOut containsString:@"Signature=adhoc"])
            printf("  signature   : AD-HOC — every reinstall orphans the Accessibility grant.\n"
                   "                Create the identity (scripts/setup.sh does this) and reinstall.\n");
        else
            printf("  signature   : %s\n",
                   [[csOut componentsSeparatedByString:@"\n"].firstObject UTF8String] ?: "unknown");
        BOOL running = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.stickshift.gearbox"].count > 0;
        printf("  running     : %s\n", running ? "yes" : "no (open ~/Applications/StickShift.app)");
        if (running) printf("  note        : if the app was launched BEFORE Accessibility was granted,\n"
                            "                quit and reopen it — grants attach at process launch.\n");
    }

    printf("\nRecent outcomes (~/.stickshift/log):\n");
    NSString *logPath = [NSHomeDirectory() stringByAppendingPathComponent:@".stickshift/log"];
    NSString *logTxt = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
    if (!logTxt.length) printf("  (no attempts logged yet)\n");
    else {
        NSArray *ll = [logTxt componentsSeparatedByString:@"\n"];
        NSInteger start = MAX(0, (NSInteger)ll.count - 4);
        for (NSInteger i = start; i < (NSInteger)ll.count; i++)
            if ([ll[i] length]) printf("  %s\n", [ll[i] UTF8String]);
    }

    printf("\nFocused-pane attribution (read-only):\n");
    pid_t term = override ?: [AXState frontmostPid];
    NSString *bundle = override ? ([NSRunningApplication runningApplicationWithProcessIdentifier:term].bundleIdentifier ?: @"?")
                                : [AXState frontmostBundleId];
    if (![cfg.enabledTerminals containsObject:bundle]) {
        printf("  frontmost %s is not an enabled terminal — focus a terminal pane and re-run.\n", bundle.UTF8String);
    } else {
        AttributionResult *ar = [Attribution attributeFocusedTerminal:term invokingTty:invokingTty()];
        printf("  result      : %s\n", ShiftReasonCode(ar.reason).UTF8String);
        printf("  detail      : %s\n", ar.detail.UTF8String ?: "");
        if (ar.target) {
            printf("  agent pid   : %d  tty %s\n", ar.target.agentPid, ar.target.tty.UTF8String);
            printf("  signature   : team=%s id=%s valid=%d qualified=%d version=%s\n",
                   ar.target.identity.teamId.UTF8String ?: "?",
                   ar.target.identity.codeId.UTF8String ?: "?",
                   ar.target.identity.signatureValid, ar.target.identity.qualified,
                   ar.target.identity.version.UTF8String ?: "?");
        }
    }
    printf("\nInvoking tty (SELF_TARGET guard): %s\n", invokingTty().UTF8String ?: "(none)");
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSArray<NSString*> *args = [[NSProcessInfo processInfo] arguments];
        NSString *cmd = args.count > 1 ? args[1] : @"help";
        Config *cfg = [Config load];

        if ([cmd isEqualToString:@"help"] || [cmd isEqualToString:@"-h"] || [cmd isEqualToString:@"--help"]) {
            printf("shift <gear>        attribute + (dry-run) plan a model switch of the focused pane\n");
            printf("shift <gear> --commit   actually perform the switch\n");
            printf("shift status        read the focused pane's agent/model/state (read-only)\n");
            printf("shift doctor        permissions, config, and attribution self-check\n");
            printf("gears: 1..5, R, ULTRA\n");
            return 0;
        }
        if ([cmd isEqualToString:@"status"]) return cmdStatus(cfg, overridePid(args));
        if ([cmd isEqualToString:@"doctor"]) return cmdDoctor(cfg, overridePid(args));

        // gear command
        NSString *gear = cmd;
        if (![[cfg allGears] containsObject:gear.uppercaseString]) {
            fprintf(stderr, "unknown gear '%s' (use 1..5, R, ULTRA)\n", gear.UTF8String);
            return 2;
        }
        BOOL commit = [args containsObject:@"--commit"];
        BOOL forceDefaults = [args containsObject:@"--force-defaults"];
        if (cfg.malformed && commit && !forceDefaults) {
            printf("BAD_CONFIG — %s (pass --force-defaults to run on built-in defaults)\n", cfg.loadError.UTF8String);
            return 1;
        }
        if (cfg.malformed && forceDefaults) cfg = [Config defaults];

        // --dwell <seconds>: wait for the user to focus the target pane first.
        double dwell = 0;
        NSUInteger di = [args indexOfObject:@"--dwell"];
        if (di != NSNotFound && di + 1 < args.count) dwell = [args[di+1] doubleValue];
        if (dwell > 0 && !waitForDwell(cfg, dwell)) {
            printf("SELF_TARGET — no qualifying agent pane was focused within %.0fs\n", dwell);
            return 1;
        }

        // The interprocess lock is acquired inside the engine's commit path (shared by
        // CLI and app), so we don't take it here (that would self-deadlock).
        // With --dwell the invoking tty is intentionally NOT the target, so don't pass it
        // as the SELF_TARGET key (the user dwelled onto a different pane).
        SwitchOutcome *o = [Switch runGear:gear.uppercaseString config:cfg
                               invokingTty:(dwell > 0 ? nil : invokingTty()) commit:commit
                          terminalOverride:overridePid(args)];
        printf("%s\n", [o describe].UTF8String);
        StickShiftLogLine([NSString stringWithFormat:@"gear=%@ commit=%d -> %@", gear.uppercaseString, commit, [o describe]]);
        if (o.plan && !o.committed && o.reason == ShiftOK)
            printf("plan: %s\n(dry run — pass --commit to apply)\n", o.plan.summary.UTF8String);
        return o.reason == ShiftOK || o.reason == ShiftChanged || o.reason == ShiftAlreadySet ? 0 : 1;
    }
}
