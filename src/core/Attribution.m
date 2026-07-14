#import "Attribution.h"
#import "Proc.h"

@implementation TargetTuple @end
@implementation AttributionResult @end

@implementation Attribution

static AttributionResult *fail(ShiftReason r, NSString *d) {
    AttributionResult *x = [AttributionResult new]; x.reason = r; x.detail = d; return x;
}

+ (ProcRow *)nativeCodexInGroup:(pid_t)pgid rows:(NSArray<ProcRow *> *)rows {
    for (ProcRow *r in rows)
        if (r.pgid == pgid && [r.comm isEqualToString:@"codex"]) return r;  // exact "codex", same fg group
    return nil;
}

// Claude's 📂 basename may be the cwd basename, an ancestor path component, or an
// existing child directory of the process cwd. Filesystem-verified for the child case.
// Tiered so multiple candidates can be ranked: an exact basename match must beat a
// session that merely sits somewhere under (or above) a dir with that name.
+ (int)claudeCwdMatchTier:(NSString *)cwd hint:(NSString *)hint {
    if (!cwd.length || !hint.length) return 0;
    if ([[cwd lastPathComponent] isEqualToString:hint]) return 1;
    if ([[cwd pathComponents] containsObject:hint]) return 2;
    NSString *child = [cwd stringByAppendingPathComponent:hint];
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:child isDirectory:&isDir] && isDir) return 3;
    return 0;
}
+ (BOOL)claudeCwd:(NSString *)cwd matchesHint:(NSString *)hint {
    return [self claudeCwdMatchTier:cwd hint:hint] > 0;
}

// The signed native codex image lives under the fg pgrp; for claude the fg leader IS
// the signed image. Return the image path to identify + the agent pid to bind.
+ (void)resolveAgentImageForLeader:(ProcRow *)leader
                             table:(ProcTable *)tbl
                              kind:(AgentKind)kind
                          outImage:(NSString **)outImg
                            outPid:(pid_t *)outPid {
    if (kind == AgentClaude) {
        [tbl resolvePathsFor:leader];
        *outImg = leader.image; *outPid = leader.pid; return;
    }
    // codex: leader is node wrapper (pgrp leader); bind the signed native codex in the
    // SAME fg group (sub-agent codex processes in other groups are ignored).
    ProcRow *native = [self nativeCodexInGroup:leader.pgid rows:tbl.rows];
    if (native) {
        [tbl resolvePathsFor:native];
        if (native.image.length) { *outImg = native.image; *outPid = native.pid; return; }
    }
    [tbl resolvePathsFor:leader];
    *outImg = leader.image; *outPid = leader.pid;
}

+ (AttributionResult *)attributeFocusedTerminal:(pid_t)terminalPid
                                     invokingTty:(NSString *)invokingTty {
    PaneState *pane = [AXState readFocusedPaneForTerminal:terminalPid];
    if (!pane.hasFocusedWindow) return fail(ShiftNoFocusedWindow, @"no AX focused window");
    if (pane.agent == AgentUnknown) return fail(ShiftNoAgent, @"focused pane is not a recognized agent");
    // Claude always renders its 📂 cwd chip, so an empty hint there is a hard stop.
    // Codex's footer ALTERNATES between the path and a command hint bar (live
    // 2026-07-13), so a codex pane may legitimately have no hint — fall through and
    // bind only if exactly one codex session exists (a tie still refuses below).
    if (!pane.cwdHint.length && pane.agent != AgentCodex)
        return fail(ShiftAmbiguousAgent, @"no cwd hint from pane content");

    // Process safety gate: local foreground agents whose kind+cwd match the pane.
    ProcTable *tbl = [ProcTable snapshot];
    NSSet *desc = [tbl descendantsOf:terminalPid];
    NSMutableSet<NSNumber*> *ttys = [NSMutableSet set];
    for (ProcRow *r in tbl.rows)
        if ([desc containsObject:@(r.pid)] && r.tdev && r.tdev != (dev_t)-1) [ttys addObject:@(r.tdev)];

    NSMutableArray<TargetTuple*> *matches = [NSMutableArray array];
    NSMutableArray<NSNumber*> *tiers = [NSMutableArray array];   // match strength per candidate
    NSMutableArray<NSString*> *consideredLog = [NSMutableArray array]; // forensic trail for a zero-match failure
    for (NSNumber *td in ttys) {
        dev_t tdev = (dev_t)td.integerValue;
        ProcRow *leader = [tbl foregroundLeaderForTdev:tdev amongDescendants:desc];
        if (!leader) continue;
        // kind of this session from comm
        AgentKind kind = AgentUnknown;
        BOOL claudeLeader = [leader.comm hasPrefix:@"claude"];
        BOOL codexSession = [self nativeCodexInGroup:leader.pgid rows:tbl.rows] != nil;
        if (claudeLeader) kind = AgentClaude; else if (codexSession) kind = AgentCodex; else {
            [consideredLog addObject:[NSString stringWithFormat:@"%@ leader=%@ not an agent",
                [ProcTable ttyNameForDev:tdev], leader.comm]];
            continue;
        }
        if (kind != pane.agent) {
            [consideredLog addObject:[NSString stringWithFormat:@"%@ kind=%@ != pane",
                [ProcTable ttyNameForDev:tdev], kind == AgentClaude ? @"claude" : @"codex"]];
            continue;
        }

        NSString *img = nil; pid_t apid = -1;
        [self resolveAgentImageForLeader:leader table:tbl kind:kind outImage:&img outPid:&apid];
        [tbl resolvePathsFor:leader];
        NSString *cwd = leader.cwd ?: @"";
        // cwd match: claude pane gives a basename that can be a PROJECT subdir of the
        // process cwd (verified: Claude's 📂 shows a working subdir, e.g. "demo-site"
        // while the process cwd is the parent directory). So accept when the
        // hint is the cwd basename, a path component of the cwd (ancestor case), or an
        // existing child directory of the cwd (descendant case). Codex gives full path.
        int tier = 0;
        if (pane.agent == AgentClaude)
            tier = [self claudeCwdMatchTier:cwd hint:pane.cwdHint];
        else if (!pane.cwdHint.length)
            tier = 3;   // hint-bar footer, no path: weakest tier — a singleton codex
                        // session binds; two codex sessions tie at 3 and refuse
        else
            tier = [cwd isEqualToString:pane.cwdHint] ? 1
                 : ([pane.cwdHint hasPrefix:[cwd stringByAppendingString:@"/"]] ? 2 : 0);
        if (!tier) {
            [consideredLog addObject:[NSString stringWithFormat:@"%@ cwd='%@' no tier vs hint",
                [ProcTable ttyNameForDev:tdev], cwd]];
            continue;
        }

        AgentIdentity *ident = [[Manifest shared] identifyImage:img kindHint:kind];
        TargetTuple *t = [TargetTuple new];
        t.terminalPid = terminalPid;
        t.windowTitle = pane.windowTitle;
        t.geometry = pane.focusedFrame;
        t.agentPid = apid;
        t.agentStartSec = [tbl rowForPid:apid].startSec;
        t.tty = [ProcTable ttyNameForDev:tdev];
        t.foregroundPgrp = leader.pgid;
        t.identity = ident;
        t.pane = pane;
        [matches addObject:t];
        [tiers addObject:@(tier)];
    }

    if (matches.count == 0) {
        // Forensic detail: WHY each tty was rejected, plus the exact hint we matched
        // against. Cwd paths are user directories, not pane content, so logging them
        // keeps the privacy rule while making a zero-match diagnosable from the log.
        return fail(ShiftRemoteSession, ([NSString stringWithFormat:
            @"no local agent matches the focused pane — hint='%@'; considered: %@",
            pane.cwdHint, consideredLog.count ? [consideredLog componentsJoinedByString:@"; "] : @"(none)"]));
    }
    if (matches.count > 1) {
        // Prefer the strongest cwd-match tier: an exact-basename session beats one that
        // is merely nested under (or a parent of) a dir named like the hint. Only a tie
        // at the best tier is truly ambiguous — a session in 'X' no longer blocks on a
        // second session in 'X/sub' (live failure: Parent Project / Sub Project).
        int best = INT_MAX;
        for (NSNumber *n in tiers) best = MIN(best, n.intValue);
        NSMutableArray<TargetTuple*> *strongest = [NSMutableArray array];
        for (NSUInteger i = 0; i < matches.count; i++)
            if (tiers[i].intValue == best) [strongest addObject:matches[i]];
        if (strongest.count > 1) return fail(ShiftAmbiguousAgent, ([NSString stringWithFormat:
            @"%lu agents equally match '%@' — Warp can't say which pane is which; run this one in a unique directory",
            (unsigned long)strongest.count, pane.cwdHint]));
        [matches setArray:strongest];
    }

    TargetTuple *t = matches[0];
    // SELF_TARGET: refuse if the attributed tty is our invoking shell's tty.
    if (invokingTty.length && [t.tty isEqualToString:invokingTty])
        return fail(ShiftSelfTarget, @"attributed pane is this CLI's own shell");
    if (!t.identity.qualified)
        return fail(ShiftUnsupportedAgentVersion, ([NSString stringWithFormat:@"agent version %@ not qualified", t.identity.version ?: @"?"]));

    AttributionResult *ok = [AttributionResult new];
    ok.reason = ShiftOK; ok.target = t;
    ok.detail = [NSString stringWithFormat:@"%@ pid=%d %@ %@",
                 t.identity.name ?: (t.identity.kind==AgentClaude?@"claude":@"codex"),
                 t.agentPid, t.tty, t.identity.version ?: @"?"];
    return ok;
}

@end
