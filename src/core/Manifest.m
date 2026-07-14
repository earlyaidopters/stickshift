#import "Manifest.h"
#import <Security/Security.h>

@implementation AgentIdentity @end

@implementation Manifest

+ (instancetype)shared {
    static Manifest *m; static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [Manifest new]; });
    return m;
}

// Static requirement checks from spike 5.
static NSString *teamForKind(AgentKind k) { return k == AgentClaude ? @"Q6L2SF6YDW" : @"2DC432GLL2"; }
static NSString *codeIdForKind(AgentKind k) { return k == AgentClaude ? @"com.anthropic.claude-code" : @"codex"; }

// Qualified version set (extend as qualification runs add versions).
static NSSet *qualifiedVersions(AgentKind k) {
    return k == AgentClaude ? [NSSet setWithArray:@[@"2.1.205"]]
                            : [NSSet setWithArray:@[@"0.144.1"]];
}

- (NSString *)codeSignInfoForPath:(NSString *)path team:(NSString **)outTeam ident:(NSString **)outId {
    SecStaticCodeRef code = NULL;
    NSURL *url = [NSURL fileURLWithPath:path];
    if (SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code) != errSecSuccess) return nil;
    // validate signature integrity
    OSStatus valid = SecStaticCodeCheckValidity(code, kSecCSDefaultFlags, NULL);
    CFDictionaryRef info = NULL;
    SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
    NSString *team = nil, *ident = nil;
    if (info) {
        NSDictionary *d = (__bridge NSDictionary *)info;
        team = d[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
        ident = d[(__bridge NSString *)kSecCodeInfoIdentifier];
        CFRelease(info);
    }
    if (outTeam) *outTeam = team;
    if (outId) *outId = ident;
    if (code) CFRelease(code);
    return valid == errSecSuccess ? @"valid" : @"invalid";
}

// Resolve version from the nearest ancestor package.json. Layouts differ per agent:
// claude-code has bin/claude.exe one level below package.json, but codex nests the
// real binary at vendor/<triple>/bin/codex, THREE levels below its package.json
// (live 2026-07-13: the one-level lookup returned nil and a fully qualified codex
// was refused as "version ? not qualified"). Walk up a bounded number of levels.
- (NSString *)versionFromImage:(NSString *)imagePath kind:(AgentKind)kind {
    NSString *dir = [imagePath stringByDeletingLastPathComponent];         // .../bin
    for (int up = 0; up < 6 && dir.length > 1; up++) {
        dir = [dir stringByDeletingLastPathComponent];
        NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"package.json"]];
        if (!d) continue;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![j[@"version"] isKindOfClass:[NSString class]]) continue;
        // codex-darwin-arm64 version is "0.144.1-darwin-arm64"; normalize
        NSString *v = j[@"version"];
        NSRange dash = [v rangeOfString:@"-darwin"];
        return dash.location != NSNotFound ? [v substringToIndex:dash.location] : v;
    }
    return nil;
}

// Version drift policy. Agents ship patch releases weekly; the TUI vocabulary this
// engine drives (commands, picker rows, dialogs, footers) is re-proven at runtime on
// every shift, so version is a drift SIGNAL, not an identity gate. Exact and
// same-major.minor versions are treated as known-good; an out-of-series version on
// an authentic binary is driven with a logged warning (live 2026-07-13: the exact
// pin refused codex 0.144.3 minutes after a routine update — its second false
// refusal, against zero true saves).
+ (VersionMatch)matchForVersion:(NSString *)v kind:(AgentKind)kind {
    if (!v.length) return VersionUnknown;
    NSSet *qual = qualifiedVersions(kind);
    if ([qual containsObject:v]) return VersionExact;
    NSArray *vp = [v componentsSeparatedByString:@"."];
    if (vp.count >= 2) {
        NSString *series = [NSString stringWithFormat:@"%@.%@.", vp[0], vp[1]];
        for (NSString *q in qual)
            if ([q hasPrefix:series]) return VersionSameSeries;
    }
    return VersionDrift;
}

- (AgentIdentity *)identifyImage:(NSString *)imagePath kindHint:(AgentKind)hint {
    AgentIdentity *id_ = [AgentIdentity new];
    id_.imagePath = imagePath;
    id_.kind = hint;
    if (!imagePath.length) return id_;
    NSString *team = nil, *ident = nil;
    NSString *validity = [self codeSignInfoForPath:imagePath team:&team ident:&ident];
    id_.teamId = team; id_.codeId = ident;
    id_.signatureValid = [validity isEqualToString:@"valid"];
    // kind from signature if not hinted
    if (hint == AgentUnknown) {
        if ([team isEqualToString:teamForKind(AgentClaude)]) id_.kind = AgentClaude;
        else if ([team isEqualToString:teamForKind(AgentCodex)]) id_.kind = AgentCodex;
    }
    id_.version = [self versionFromImage:imagePath kind:id_.kind];
    id_.versionMatch = [Manifest matchForVersion:id_.version kind:id_.kind];
    // HARD gates: authentic signature, right team, right identifier, known kind,
    // and a resolvable version (a missing package.json means we cannot even say
    // what we are driving). Version DRIFT is not a hard gate — see matchForVersion.
    BOOL teamOk = [team isEqualToString:teamForKind(id_.kind)];
    BOOL idOk = [ident isEqualToString:codeIdForKind(id_.kind)];
    id_.qualified = id_.signatureValid && teamOk && idOk
                 && id_.kind != AgentUnknown && id_.versionMatch != VersionUnknown;
    return id_;
}

- (BOOL)isTupleQualifiedForKind:(AgentKind)kind model:(NSString *)model effort:(NSString *)effort {
    // Effort allowlists from spike 7.
    NSSet *claudeEfforts = [NSSet setWithArray:@[@"low",@"medium",@"high",@"xhigh",@"max",@"ultracode",@"auto"]];
    NSSet *codexEfforts  = [NSSet setWithArray:@[@"low",@"medium",@"high",@"xhigh",@"max",@"ultra"]];
    if (kind == AgentClaude) {
        if (effort && ![claudeEfforts containsObject:effort]) return NO;
        return model.length > 0;
    }
    if (kind == AgentCodex) {
        // codex effort rows are model-dependent; ultra only on some models. Enforce
        // the base allowlist here; the picker itself gates model-specific availability.
        if (effort && ![codexEfforts containsObject:effort]) return NO;
        return model.length > 0;
    }
    return NO;
}

@end
