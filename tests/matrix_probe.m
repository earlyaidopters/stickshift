// Live-machine pipeline matrix: verifies THIS machine's installed agent binaries
// qualify, then pushes every (model, effort) combination the UI can fire through
// tuple qualification, plan building, display mapping, and keyboard typeability.
// Everything short of touching a live pane. Run via `make matrix`.
//
// Exit 0 = every combination passes. Any FAIL line means an agent pointed at this
// repo should fix that stage before telling the user the install works.
#import <Foundation/Foundation.h>
#import "Manifest.h"
#import "Protocol.h"
#import "AXState.h"
#import "Inject.h"

static int bad = 0;
static void req(BOOL ok, NSString *what) {
    if (!ok) { printf("FAIL  %s\n", what.UTF8String); bad++; }
}

// Find an installed agent binary. Checks the common npm layouts for both Apple
// Silicon and Intel Homebrew prefixes, then falls back to `which`.
static NSString *findBinary(NSArray<NSString*> *candidates, NSString *whichName) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *c in candidates)
        if ([fm isExecutableFileAtPath:c]) return c;
    // `which` through the user's login shell so nvm/volta paths resolve
    NSTask *t = [NSTask new];
    t.launchPath = @"/bin/zsh";
    t.arguments = @[@"-lc", [NSString stringWithFormat:@"which %@ 2>/dev/null", whichName]];
    NSPipe *p = [NSPipe pipe]; t.standardOutput = p; t.standardError = [NSPipe pipe];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) { return nil; }
    NSString *out = [[[NSString alloc] initWithData:[p.fileHandleForReading readDataToEndOfFile]
        encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!out.length) return nil;
    // resolve symlinks (claude is usually a symlink into node_modules)
    NSString *resolved = [out stringByResolvingSymlinksInPath];
    return [fm isExecutableFileAtPath:resolved] ? resolved : out;
}

int main(void) { @autoreleasepool {
    printf("== live binary qualification ==\n");
    NSString *codexBin = findBinary(@[
        @"/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
        @"/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex",
    ], @"codex");
    NSString *claudeBin = findBinary(@[
        @"/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
        @"/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
    ], @"claude");

    if (claudeBin) {
        AgentIdentity *cl = [[Manifest shared] identifyImage:claudeBin kindHint:AgentClaude];
        printf("claude: %s\n        ver=%s team=%s sig=%d qualified=%d\n", claudeBin.UTF8String,
            cl.version.UTF8String ?: "?", cl.teamId.UTF8String ?: "?", cl.signatureValid, cl.qualified);
        req(cl.qualified, @"installed claude binary qualifies (if version differs, see README 'Agent qualification')");
    } else printf("claude: not found on this machine (skipping qualification)\n");
    if (codexBin) {
        AgentIdentity *cx = [[Manifest shared] identifyImage:codexBin kindHint:AgentCodex];
        printf("codex : %s\n        ver=%s team=%s sig=%d qualified=%d\n", codexBin.UTF8String,
            cx.version.UTF8String ?: "?", cx.teamId.UTF8String ?: "?", cx.signatureValid, cx.qualified);
        req(cx.qualified, @"installed codex binary qualifies (if version differs, see README 'Agent qualification')");
    } else printf("codex : not found on this machine (skipping qualification)\n");
    if (!claudeBin && !codexBin)
        printf("NOTE: neither agent found; matrix still validates plans + typeability.\n");

    printf("\n== full UI matrix ==\n");
    NSDictionary *claudeM = @{@"haiku":@"Haiku 4.5", @"sonnet":@"Sonnet 5",
                              @"default":@"Opus 4.8", @"fable":@"Fable 5"};
    NSArray *claudeE = @[@"low",@"medium",@"high",@"xhigh",@"max",@"ultracode"];
    NSArray *codexM = @[@"gpt-5.4-mini",@"gpt-5.4",@"gpt-5.5",
                        @"gpt-5.6-luna",@"gpt-5.6-terra",@"gpt-5.6-sol"];
    NSArray *codexE = @[@"low",@"medium",@"high",@"xhigh",@"max"];
    int combos = 0;

    for (NSString *m in claudeM) for (NSString *e in [claudeE arrayByAddingObject:@""]) {
        NSString *eff = e.length ? e : nil;
        req([[Manifest shared] isTupleQualifiedForKind:AgentClaude model:m effort:eff],
            ([NSString stringWithFormat:@"claude tuple qualifies: %@/%@", m, eff ?: @"-"]));
        GearTuple *t = [GearTuple new]; t.model = m; t.effort = eff;
        SwitchPlan *p = [ShiftProtocol planForKind:AgentClaude tuple:t];
        req(p && p.steps.count && p.evidenceNeedles.count,
            ([NSString stringWithFormat:@"claude plan builds: %@/%@", m, eff ?: @"-"]));
        req([p.expectedModelDisplay isEqualToString:claudeM[m]],
            ([NSString stringWithFormat:@"claude display: %@ -> %@", m, claudeM[m]]));
        for (PlanStep *s in p.steps) if (s.kind == StepTypeText)
            req([Inject canTypeText:s.text],
                ([NSString stringWithFormat:@"typeable on current layout: '%@'", s.text]));
        combos++;
    }
    for (NSString *m in codexM) {
        NSArray *effs = [m isEqualToString:@"gpt-5.6-sol"]
            ? [codexE arrayByAddingObject:@"ultra"] : codexE;
        for (NSString *e in [effs arrayByAddingObject:@""]) {
            NSString *eff = e.length ? e : nil;
            req([[Manifest shared] isTupleQualifiedForKind:AgentCodex model:m effort:eff],
                ([NSString stringWithFormat:@"codex tuple qualifies: %@/%@", m, eff ?: @"-"]));
            GearTuple *t = [GearTuple new]; t.model = m; t.effort = eff;
            SwitchPlan *p = [ShiftProtocol planForKind:AgentCodex tuple:t];
            req(p && p.steps.count,
                ([NSString stringWithFormat:@"codex plan builds: %@/%@", m, eff ?: @"-"]));
            for (PlanStep *s in p.steps) if (s.kind == StepTypeText)
                req([Inject canTypeText:s.text],
                    ([NSString stringWithFormat:@"typeable on current layout: '%@'", s.text]));
            combos++;
        }
    }
    printf("\n%d combinations checked, %d failures — %s\n", combos, bad,
           bad ? "FIX BEFORE TRUSTING LIVE" : "ALL PASS");
    return bad ? 1 : 0;
} }
