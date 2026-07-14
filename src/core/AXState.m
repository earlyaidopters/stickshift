#import "AXState.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#ifndef kAXSuccess
#define kAXSuccess 0
#endif

@implementation PaneState @end

static NSString *axCopyString(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) == kAXSuccess && v) {
        NSString *s = (CFGetTypeID(v) == CFStringGetTypeID())
            ? [NSString stringWithString:(__bridge NSString *)v] : nil;
        CFRelease(v);
        return s;
    }
    return nil;
}

static CGRect axFrame(AXUIElementRef el) {
    CFTypeRef pos = NULL, size = NULL;
    CGRect out = CGRectZero;
    if (AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &pos) == kAXSuccess && pos &&
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &size) == kAXSuccess && size) {
        CGPoint p; CGSize s;
        AXValueGetValue((AXValueRef)pos, kAXValueCGPointType, &p);
        AXValueGetValue((AXValueRef)size, kAXValueCGSizeType, &s);
        out = CGRectMake(p.x, p.y, s.width, s.height);
    }
    if (pos) CFRelease(pos);
    if (size) CFRelease(size);
    return out;
}

// Known display strings.
static NSArray<NSString*> *claudeModels(void) {
    return @[@"Opus 4.8 (1M context) (default)", @"Opus 4.8 (1M context)", @"Opus 4.8",
             @"Fable 5", @"Sonnet 5", @"Haiku 4.5"];
}
static NSArray<NSString*> *codexPlaceholders(void) {
    // The composer ghost-suggestion rotation, extracted VERBATIM from the qualified
    // codex 0.144.1 binary (strings dump, 2026-07-13) — the old partial list made
    // every unlisted suggestion read as a user draft and refuse with DRAFT_PRESENT.
    // Re-extract when qualifying a new codex version.
    return @[@"Explain this codebase",
             @"Summarize recent commits",
             @"Implement {feature}",
             @"Find and fix a bug in @filename",
             @"Write tests for @filename",
             @"Improve documentation in @filename",
             @"Run /review on my current changes",
             @"Use /skills to list available skills",
             @"Check recently modified functions for compatibility",
             @"How many files have been modified?",
             @"Will this algorithm scale well?",
             @"Ready. What would you like to work on?",
             @"Ask anything"];
}
// Claude input-box PLACEHOLDER strings (greyed hint text = empty input, not a draft).
static NSArray<NSString*> *claudePlaceholders(void) {
    return @[@"Press up to edit queued messages", @"Try \"", @"Ask Claude",
             @"Update your working directory"];
}
static NSArray<NSString*> *effortWords(void) {
    return @[@"low", @"medium", @"high", @"xhigh", @"max", @"ultracode", @"ultra",
             @"extra high", @"auto"];
}

@implementation AXState

+ (NSInteger)codexPickerRowFor:(NSString *)label inText:(NSString *)text {
    if (!label.length || !text.length) return 0;
    NSString *want = label.lowercaseString;
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *ln = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        // strip a leading selection marker "›"
        if ([ln hasPrefix:@"›"]) ln = [[ln substringFromIndex:[ln rangeOfString:@"›"].location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        // expect "N. <label> …"
        NSRange dot = [ln rangeOfString:@". "];
        if (dot.location == NSNotFound || dot.location == 0 || dot.location > 2) continue;
        NSString *numStr = [ln substringToIndex:dot.location];
        NSInteger n = numStr.integerValue;
        if (n <= 0) continue;
        NSString *rest = [[ln substringFromIndex:NSMaxRange(dot)] lowercaseString];
        // Full-token match only: 'gpt-5.4' must never select a 'gpt-5.4-mini' row.
        // The label must end exactly here or be followed by a delimiter.
        if ([rest hasPrefix:want]) {
            if (rest.length == want.length) return n;
            unichar next = [rest characterAtIndex:want.length];
            if (next == ' ' || next == '\t' || next == '(') return n;
        }
    }
    return 0;
}

+ (pid_t)frontmostPid { return [[NSWorkspace sharedWorkspace] frontmostApplication].processIdentifier; }

+ (pid_t)keyboardFocusPid {
    AXUIElementRef sys = AXUIElementCreateSystemWide();
    CFTypeRef focused = NULL;
    pid_t pid = -1;
    if (AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute, &focused) == kAXErrorSuccess && focused) {
        AXUIElementGetPid((AXUIElementRef)focused, &pid);
        CFRelease(focused);
    }
    CFRelease(sys);
    return pid;
}
+ (NSString *)frontmostBundleId { return [[NSWorkspace sharedWorkspace] frontmostApplication].bundleIdentifier ?: @""; }

+ (PaneState *)readFocusedPaneForTerminal:(pid_t)terminalPid {
    PaneState *st = [PaneState new];
    st.terminalPid = terminalPid;
    AXUIElementRef app = AXUIElementCreateApplication(terminalPid);
    CFTypeRef win = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &win) == kAXSuccess && win) {
        st.hasFocusedWindow = YES;
        st.windowTitle = axCopyString((AXUIElementRef)win, kAXTitleAttribute);
        CFRelease(win);
    }
    CFTypeRef focused = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused) == kAXSuccess && focused) {
        st.focusedFrame = axFrame((AXUIElementRef)focused);
        NSString *text = axCopyString((AXUIElementRef)focused, kAXValueAttribute);
        st.paneText = text;
        CFRelease(focused);
    }
    CFRelease(app);
    if (st.paneText.length) [self classifyText:st.paneText into:st];
    return st;
}

// A footer/banner capture qualifies as a cwd only if it reads like a directory:
// " | " separators and truncation ellipses are UI chrome. Returns the trimmed,
// ~-expanded path (attribution compares absolute process cwds), or nil.
+ (NSString *)plausibleCwd:(NSString *)capture {
    NSString *cwd = [capture stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!cwd.length) return nil;
    if ([cwd containsString:@" | "] || [cwd containsString:@"…"]) return nil;
    if ([cwd hasPrefix:@"~/"])
        cwd = [NSHomeDirectory() stringByAppendingString:[cwd substringFromIndex:1]];
    return cwd;
}

+ (void)classifyText:(NSString *)text into:(PaneState *)st {
    if (!text.length) return;
    NSArray<NSString*> *lines = [text componentsSeparatedByString:@"\n"];
    NSString *lower = text.lowercaseString;

    // --- agent detection ---
    BOOL looksClaude = ([text containsString:@"📂"] && [text containsString:@" · "]) ||
                       [text containsString:@"bypass permissions"] ||
                       [text containsString:@"for agents"] ||
                       [lower containsString:@"claude code v"] ||
                       ([text containsString:@"5h:"] && [text containsString:@"7d:"]);
    BOOL looksCodex = [text containsString:@"OpenAI Codex"] ||
                      [text containsString:@"/model to change"] ||
                      ([lower rangeOfString:@"gpt-" ].location != NSNotFound &&
                       ([text containsString:@" · /"] || [text containsString:@" ~/"]));
    if (looksClaude && !looksCodex) st.agent = AgentClaude;
    else if (looksCodex && !looksClaude) st.agent = AgentCodex;
    else if (looksClaude && looksCodex) st.agent = AgentClaude; // claude chrome is more specific
    else st.agent = AgentUnknown;

    // --- busy / dialog (bottom-anchored: the live spinner/dialog sit just above the
    // input, so we only trust the last lines — conversation scrollback that quotes these
    // markers must not false-trigger) ---
    NSUInteger btail = lines.count > 16 ? lines.count - 16 : 0;
    NSArray *btmLines = [lines subarrayWithRange:NSMakeRange(btail, lines.count - btail)];
    NSString *btm = [btmLines componentsJoinedByString:@"\n"];
    BOOL busy = [btm containsString:@"esc to interrupt"] || [btm containsString:@"• Working"];
    // Also catch the working spinner that omits "esc to interrupt" (e.g. a running loop:
    // "✳ Fluttering… (10m 12s · ↓ 34.4k tokens)"). A bottom line starting with a spinner
    // glyph and carrying an elapsed-time paren is a positive busy marker.
    if (!busy) {
        NSCharacterSet *spin = [NSCharacterSet characterSetWithCharactersInString:@"✻✽✢✳✶✺⚹✷✵"];
        for (NSString *ln in btmLines) {
            NSString *tr = [ln stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (tr.length && [spin characterIsMember:[tr characterAtIndex:0]] &&
                [tr containsString:@"("] && ([tr containsString:@"s"] )) { busy = YES; break; }
        }
    }
    st.busy = busy;
    // Dialog detection is anchored to the RENDERED option LINES at the bottom — the
    // title line "Switch model?", an option line starting "Yes, switch to", and an
    // option line that is exactly "No, go back". Conversation scrollback that merely
    // mentions these phrases in prose never produces them as separate short lines, so it
    // does not false-trigger (PLAN item 20; found live against this very session).
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    BOOL dTitle = NO, dYes = NO, dNo = NO;
    for (NSString *ln in btmLines) {
        NSString *s = [ln stringByTrimmingCharactersInSet:ws];
        if ([s hasPrefix:@"❯"]) s = [[s substringFromIndex:[s rangeOfString:@"❯"].location + 1] stringByTrimmingCharactersInSet:ws];
        if ([s hasPrefix:@"1."]) s = [[s substringFromIndex:2] stringByTrimmingCharactersInSet:ws];
        else if ([s hasPrefix:@"2."]) s = [[s substringFromIndex:2] stringByTrimmingCharactersInSet:ws];
        // Two switch-confirm dialogs exist (both live-captured): "Switch model?" and,
        // mid-conversation when the cache would be re-read, "Change effort level?".
        if ([s isEqualToString:@"Switch model?"] || [s isEqualToString:@"Change effort level?"]) dTitle = YES;
        else if ([s hasPrefix:@"Yes, switch to"]) { dYes = YES; st.dialogTargetDisplay = [[s substringFromIndex:@"Yes, switch to".length] stringByTrimmingCharactersInSet:ws]; }
        else if ([s isEqualToString:@"No, go back"]) dNo = YES;
    }
    st.switchDialogOpen = dTitle && dYes && dNo;
    // The switch/effort confirm dialogs are Claude-only chrome, and while one is up
    // Claude HIDES the status line + composer — every normal agent marker vanishes,
    // so the pane classified as AgentUnknown and revalidation refused to answer the
    // dialog we ourselves raised (live 2026-07-13: NO_AGENT before confirming).
    if (st.agent == AgentUnknown && st.switchDialogOpen) st.agent = AgentClaude;

    // --- model + effort ---
    if (st.agent == AgentClaude) {
        // Parse the STATUS LINE only: "📂 <cwd>  ·  <Model>  [▰.. or /rc]". Anchoring to
        // this line (not arbitrary text) avoids matching model names in scrollback such
        // as a prior "Set model to X" confirmation.
        for (NSString *ln in lines) {
            NSRange f = [ln rangeOfString:@"📂 "];
            if (f.location == NSNotFound) continue;
            NSString *rest = [ln substringFromIndex:NSMaxRange(f)];
            NSArray *parts = [rest componentsSeparatedByString:@"·"];
            if (parts.count >= 1)
                st.cwdHint = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (parts.count >= 2) {
                NSString *mseg = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                // cut at the progress bar, a big gap, or /rc
                for (NSString *stopper in @[@"▰", @"▱", @"  ", @"/rc"]) {
                    NSRange sr = [mseg rangeOfString:stopper];
                    if (sr.location != NSNotFound) mseg = [mseg substringToIndex:sr.location];
                }
                mseg = [mseg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                for (NSString *m in claudeModels()) if ([mseg isEqualToString:m]) { st.modelText = m; break; }
                if (!st.modelText && mseg.length) st.modelText = mseg; // unknown but present
            }
            break;
        }
        // effort chip: "◉ xhigh · /effort" or "○ low · /effort"
        for (NSString *e in effortWords()) {
            NSString *needle = [NSString stringWithFormat:@" %@ · /effort", e];
            if ([text containsString:needle]) { st.effortText = e; break; }
        }
    } else if (st.agent == AgentCodex) {
        // Footer formats (all live-captured): "gpt-5.6-sol low · /path" (older),
        // "gpt-5.6-sol low      ~/path" (current), and a HINT-BAR mode where the
        // path slot shows command help instead — "gpt-5.6-sol low   /model to
        // change | …" (live 2026-07-13: that hint text was captured as the cwd and
        // attribution matched nothing). Model/effort come from the LAST footer
        // render; the cwd only from a capture that looks like a path — a " | " or
        // a truncation ellipsis marks UI chrome, not a directory.
        NSError *err = nil;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
            @"(gpt-[A-Za-z0-9._-]+)\\s+(extra high|low|medium|high|xhigh|max|ultra)\\s+(?:·\\s+)?((?:/|~/)[^\\n]+)"
            options:0 error:&err];
        for (NSTextCheckingResult *mm in [re matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
            st.modelText = [text substringWithRange:[mm rangeAtIndex:1]];
            st.effortText = [text substringWithRange:[mm rangeAtIndex:2]];
            NSString *cwd = [self plausibleCwd:[text substringWithRange:[mm rangeAtIndex:3]]];
            if (cwd) st.cwdHint = cwd;
        }
        if (!st.cwdHint.length) {
            // Banner fallback: the session header prints "directory:  ~/path".
            NSRegularExpression *dre = [NSRegularExpression regularExpressionWithPattern:
                @"directory:\\s+((?:/|~/)[^\\n]+)" options:0 error:&err];
            for (NSTextCheckingResult *dm in [dre matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
                NSString *cwd = [self plausibleCwd:[text substringWithRange:[dm rangeAtIndex:1]]];
                if (cwd) st.cwdHint = cwd;
            }
        }
    }

    // --- input empty / draft present ---
    st.inputEmpty = [self isInputEmpty:lines agent:st.agent];

    // --- idle: positive prompt, not busy, no dialog ---
    BOOL promptPresent = (st.agent == AgentClaude && [text containsString:@"❯"]) ||
                         (st.agent == AgentCodex && [text containsString:@"›"]);
    st.idle = promptPresent && !st.busy && !st.switchDialogOpen && st.agent != AgentUnknown;
}

// Best-effort empty-input detection. Fail closed: unknown -> NO (draft present).
+ (BOOL)isInputEmpty:(NSArray<NSString*>*)lines agent:(AgentKind)agent {
    if (agent == AgentClaude) {
        // Claude input line is the LAST line beginning with "❯" (ignoring numbered
        // dialog options "❯ 1."). It sits between two rule lines above the 📂 status.
        for (NSInteger i = lines.count - 1; i >= 0; i--) {
            NSString *ln = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([ln hasPrefix:@"❯"]) {
                NSString *rest = [[ln substringFromIndex:[ln rangeOfString:@"❯"].location + 1]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (rest.length == 0) return YES;         // empty prompt
                if ([rest hasPrefix:@"1."] || [rest hasPrefix:@"2."]) continue; // dialog option, keep scanning
                for (NSString *ph in claudePlaceholders()) if ([rest hasPrefix:ph]) return YES; // placeholder = empty
                return NO;                                 // draft present
            }
        }
        return NO;
    }
    if (agent == AgentCodex) {
        for (NSInteger i = lines.count - 1; i >= 0; i--) {
            NSString *ln = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([ln hasPrefix:@"›"]) {
                NSString *rest = [[ln substringFromIndex:[ln rangeOfString:@"›"].location + 1]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (rest.length == 0) return YES;
                for (NSString *ph in codexPlaceholders()) if ([rest isEqualToString:ph]) return YES;
                return NO;
            }
        }
        return NO;
    }
    return NO;
}

@end
