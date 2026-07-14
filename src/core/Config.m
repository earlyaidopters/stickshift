#import "Config.h"
#import <sys/stat.h>

@implementation GearTuple @end

@implementation Config {
    NSDictionary<NSString*, NSDictionary<NSString*, GearTuple*>*> *_gears; // gear -> kindName -> tuple
}

+ (NSString *)configPath {
    const char *o = getenv("STICKSHIFT_CONFIG");
    if (o && *o) return [NSString stringWithUTF8String:o];
    return [NSHomeDirectory() stringByAppendingPathComponent:@".stickshift/config.toml"];
}

+ (BOOL)isInjectionSafe:(NSString *)s {
    if (s.length == 0) return NO;
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._[]-"];
    return [s rangeOfCharacterFromSet:ok.invertedSet].location == NSNotFound;
}

static GearTuple *T(NSString *model, NSString *effort) {
    GearTuple *g = [GearTuple new]; g.model = model; g.effort = effort; return g;
}

- (void)installDefaults {
    // From spike 7. Claude models are inline /model args; Codex models are picker labels.
    _gears = @{
      @"1":     @{@"claude": T(@"haiku", nil),   @"codex": T(@"gpt-5.4-mini", @"medium")},
      @"2":     @{@"claude": T(@"sonnet", nil),  @"codex": T(@"gpt-5.6-luna", @"medium")},
      @"3":     @{@"claude": T(@"default", nil), @"codex": T(@"gpt-5.6-terra", @"medium")},
      @"4":     @{@"claude": T(@"fable", @"high"),@"codex": T(@"gpt-5.6-sol", @"high")},
      @"5":     @{@"claude": T(@"fable", @"max"), @"codex": T(@"gpt-5.6-sol", @"max")},
      @"R":     @{@"claude": T(@"default", @"auto"), @"codex": T(@"gpt-5.6-sol", @"low")},
      @"ULTRA": @{@"claude": T(@"fable", @"ultracode"), @"codex": T(@"gpt-5.6-sol", @"ultra")},
    };
    self.dialogPolicy = DialogAsk;
    self.autoAnswerEnabled = NO;
    // v1 ships Warp only — the one terminal verified end-to-end. Terminal.app needs its
    // own tty-join attribution provider (its AX structure differs and a deep AX walk can
    // block); it is intentionally NOT enabled until that provider is built and qualified.
    self.enabledTerminals = @[@"dev.warp.Warp-Stable"];
}

- (GearTuple *)tupleForGear:(NSString *)gear kind:(AgentKind)kind {
    NSString *kn = kind == AgentClaude ? @"claude" : (kind == AgentCodex ? @"codex" : nil);
    if (!kn) return nil;
    return _gears[gear.uppercaseString][kn] ?: _gears[gear][kn];
}

- (NSArray<NSString*> *)allGears { return @[@"1",@"2",@"3",@"4",@"5",@"R",@"ULTRA"]; }

// --- file safety (PLAN item 11) ---
+ (BOOL)fileIsSafe:(NSString *)path error:(NSString **)err {
    const char *p = path.fileSystemRepresentation;
    struct stat st;
    if (lstat(p, &st) != 0) { if (err) *err = @"stat failed"; return NO; }
    if (S_ISLNK(st.st_mode)) { if (err) *err = @"config is a symlink"; return NO; }
    if (st.st_uid != getuid()) { if (err) *err = @"config not owned by user"; return NO; }
    if (st.st_mode & (S_IWGRP | S_IWOTH)) { if (err) *err = @"config group/world-writable"; return NO; }
    return YES;
}

+ (instancetype)defaults {
    Config *c = [Config new];
    [c installDefaults];
    return c;
}

+ (instancetype)load {
    Config *c = [Config new];
    [c installDefaults];
    NSString *path = [self configPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) { c.loadedFromFile = NO; return c; }
    NSString *ferr = nil;
    if (![self fileIsSafe:path error:&ferr]) {
        c.malformed = YES; c.loadError = ferr; c.loadedFromFile = NO;
        return c; // callers: read-only cmds run on defaults w/ warning; mutating refuse
    }
    // Minimal TOML-subset overlay would parse here; unmapped keys keep defaults.
    // (Parser intentionally conservative; only known keys with injection-safe values
    // are honored — see docs/config.md. Defaults used where absent.)
    NSError *e = nil;
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&e];
    if (!txt) { c.malformed = YES; c.loadError = @"unreadable"; return c; }
    [c applyToml:txt];
    c.loadedFromFile = YES;
    return c;
}

// Very small TOML subset: `dialog_policy = "ask|confirm|cancel"`,
// `auto_answer = true|false`, `enabled_terminals = ["a","b"]`. Gear remaps are
// honored only when their values pass isInjectionSafe.
// Upsert only the two policy keys, keeping every other line (comments, gear remaps)
// byte-identical. Creates the file 0600 if absent. Refuses an unsafe existing file
// (symlink / wrong owner / group-writable) rather than clobbering it.
- (BOOL)persistPolicy:(NSString **)err {
    NSString *path = [Config configPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@(0700)} error:nil];
    NSMutableArray<NSString*> *lines = [NSMutableArray array];
    if ([fm fileExistsAtPath:path]) {
        NSString *ferr = nil;
        if (![Config fileIsSafe:path error:&ferr]) { if (err) *err = ferr; return NO; }
        NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (txt.length) [lines addObjectsFromArray:[txt componentsSeparatedByString:@"\n"]];
        while (lines.count && ((NSString*)lines.lastObject).length == 0) [lines removeLastObject];
    }
    NSString *pol = self.dialogPolicy == DialogConfirm ? @"confirm"
                  : (self.dialogPolicy == DialogCancel ? @"cancel" : @"ask");
    NSString *polLine = [NSString stringWithFormat:@"dialog_policy = \"%@\"", pol];
    NSString *ansLine = [NSString stringWithFormat:@"auto_answer = %@", self.autoAnswerEnabled ? @"true" : @"false"];
    BOOL hadPol = NO, hadAns = NO;
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *t = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t hasPrefix:@"dialog_policy"]) { lines[i] = polLine; hadPol = YES; }
        else if ([t hasPrefix:@"auto_answer"]) { lines[i] = ansLine; hadAns = YES; }
    }
    if (!hadPol) [lines addObject:polLine];
    if (!hadAns) [lines addObject:ansLine];
    NSString *outTxt = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    NSError *werr = nil;
    if (![outTxt writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&werr]) {
        if (err) *err = werr.localizedDescription ?: @"write failed"; return NO;
    }
    [fm setAttributes:@{NSFilePosixPermissions:@(0600)} ofItemAtPath:path error:nil];
    return YES;
}

- (void)applyToml:(NSString *)txt {
    for (NSString *raw in [txt componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@"#"] || [line hasPrefix:@"["]) continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *v = [[line substringFromIndex:NSMaxRange(eq)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *unq = [v stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
        if ([k isEqualToString:@"dialog_policy"]) {
            if ([unq isEqualToString:@"confirm"]) self.dialogPolicy = DialogConfirm;
            else if ([unq isEqualToString:@"cancel"]) self.dialogPolicy = DialogCancel;
            else self.dialogPolicy = DialogAsk;
        } else if ([k isEqualToString:@"auto_answer"]) {
            self.autoAnswerEnabled = [unq isEqualToString:@"true"];
        } else if ([k hasPrefix:@"gear."]) {
            // gear.<G>.<claude|codex> = "model" or "model effort"
            // e.g.  gear.4.claude = "fable high"   gear.ULTRA.codex = "gpt-5.6-sol ultra"
            // Documented since v1 but previously unparsed. Both tokens must pass the
            // injection-safe charset or the line is ignored (they become keystrokes).
            NSArray *kp = [k componentsSeparatedByString:@"."];
            if (kp.count != 3) continue;
            NSString *g = [kp[1] uppercaseString], *agent = kp[2];
            if (![agent isEqualToString:@"claude"] && ![agent isEqualToString:@"codex"]) continue;
            if (!_gears[g]) continue;                      // unknown gear name
            NSArray *toks = [unq componentsSeparatedByCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
            toks = [toks filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
            if (toks.count < 1 || toks.count > 2) continue;
            if (![Config isInjectionSafe:toks[0]]) continue;
            if (toks.count == 2 && ![Config isInjectionSafe:toks[1]]) continue;
            NSMutableDictionary *gears = [_gears mutableCopy];
            NSMutableDictionary *slot = [gears[g] mutableCopy];
            slot[agent] = T(toks[0], toks.count == 2 ? toks[1] : nil);
            gears[g] = slot;
            _gears = gears;
        } else if ([k isEqualToString:@"enabled_terminals"]) {
            // enabled_terminals = ["dev.warp.Warp-Stable", "com.googlecode.iterm2"]
            // Documented since v1 but previously unparsed — Warp was effectively
            // hardcoded and no other terminal could be enabled without recompiling.
            // Entries must look like bundle ids; anything else is skipped. An empty
            // or fully-invalid list keeps the compiled-in default (fail closed).
            if ([v hasPrefix:@"["] && [v hasSuffix:@"]"] && v.length >= 2) {
                NSMutableArray<NSString*> *ids = [NSMutableArray array];
                NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:
                    @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-"];
                NSString *inner = [v substringWithRange:NSMakeRange(1, v.length - 2)];
                for (NSString *part in [inner componentsSeparatedByString:@","]) {
                    NSString *b = [[part stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]]
                        stringByTrimmingCharactersInSet:
                        [NSCharacterSet characterSetWithCharactersInString:@"\""]];
                    if (b.length && [b rangeOfCharacterFromSet:ok.invertedSet].location == NSNotFound
                        && [b containsString:@"."])
                        [ids addObject:b];
                }
                if (ids.count) self.enabledTerminals = ids;
            }
        }
    }
}

@end
