// Spikes 2+3: what does Warp expose via AX for the focused window/pane, and can
// we build a focused-pane -> TTY -> foreground-process-group -> agent-PID chain?
//
// Build: clang -fobjc-arc -framework AppKit -framework ApplicationServices \
//        axdump.m -o axdump
//
// Run from the terminal under test with an agent running in the focused pane.
// Prints: (a) AX tree of the frontmost app's focused window (roles, titles,
// bounds, selected-text/value where present), and (b) the process/TTY table of
// the terminal's descendants with each TTY's foreground pgrp and the process
// that owns it.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <libproc.h>
#import <sys/sysctl.h>
#import <sys/proc_info.h>
#import <paths.h>
#ifndef kAXSuccess
#define kAXSuccess 0
#endif

static NSString *axStr(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &v) == kAXSuccess && v) {
        NSString *s = nil;
        if (CFGetTypeID(v) == CFStringGetTypeID()) s = [NSString stringWithString:(__bridge NSString *)v];
        else s = [(__bridge id)v description];
        CFRelease(v);
        return s;
    }
    return nil;
}

static NSString *axFrame(AXUIElementRef el) {
    CFTypeRef pos = NULL, size = NULL;
    NSString *out = nil;
    if (AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &pos) == kAXSuccess && pos &&
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &size) == kAXSuccess && size) {
        CGPoint p; CGSize s;
        AXValueGetValue((AXValueRef)pos, kAXValueCGPointType, &p);
        AXValueGetValue((AXValueRef)size, kAXValueCGSizeType, &s);
        out = [NSString stringWithFormat:@"[%.0f,%.0f %.0fx%.0f]", p.x, p.y, s.width, s.height];
    }
    if (pos) CFRelease(pos);
    if (size) CFRelease(size);
    return out;
}

static void walk(AXUIElementRef el, int depth, int maxDepth) {
    if (depth > maxDepth) return;
    NSString *role = axStr(el, kAXRoleAttribute) ?: @"?";
    NSString *sub  = axStr(el, kAXSubroleAttribute);
    NSString *title = axStr(el, kAXTitleAttribute);
    NSString *desc = axStr(el, kAXDescriptionAttribute);
    NSString *value = axStr(el, kAXValueAttribute);
    NSString *frame = axFrame(el);
    NSMutableString *line = [NSMutableString string];
    for (int i = 0; i < depth; i++) [line appendString:@"  "];
    [line appendFormat:@"%@", role];
    if (sub) [line appendFormat:@"/%@", sub];
    if (frame) [line appendFormat:@" %@", frame];
    if (title.length) [line appendFormat:@" title=%.40@", title];
    if (desc.length) [line appendFormat:@" desc=%.40@", desc];
    if (value.length) [line appendFormat:@" value=%.60@", [value stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]];
    printf("%s\n", line.UTF8String);

    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &children) == kAXSuccess && children) {
        NSArray *arr = (__bridge NSArray *)children;
        NSInteger n = arr.count;
        for (NSInteger i = 0; i < n && i < 40; i++)
            walk((__bridge AXUIElementRef)arr[i], depth + 1, maxDepth);
        CFRelease(children);
    }
}

// ---- process/TTY table via sysctl KERN_PROC_ALL ----
typedef struct { pid_t pid; pid_t ppid; pid_t pgid; dev_t tdev; pid_t tpgid; char comm[256]; } Proc;

static NSArray<NSValue*> *allProcs(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    sysctl(mib, 4, NULL, &len, NULL, 0);
    struct kinfo_proc *buf = malloc(len);
    sysctl(mib, 4, buf, &len, NULL, 0);
    int count = (int)(len / sizeof(struct kinfo_proc));
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        Proc p;
        p.pid = buf[i].kp_proc.p_pid;
        p.ppid = buf[i].kp_eproc.e_ppid;
        p.pgid = buf[i].kp_eproc.e_pgid;
        p.tdev = buf[i].kp_eproc.e_tdev;
        p.tpgid = buf[i].kp_eproc.e_tpgid;
        strlcpy(p.comm, buf[i].kp_proc.p_comm, sizeof(p.comm));
        [out addObject:[NSValue valueWithBytes:&p objCType:@encode(Proc)]];
    }
    free(buf);
    return out;
}

static Proc unwrap(NSValue *v) { Proc p; [v getValue:&p]; return p; }

int main(int argc, char **argv) {
    @autoreleasepool {
        pid_t termPid;
        NSString *termName, *termBundle;
        if (argc > 1) {
            termPid = (pid_t)atoi(argv[1]);
            NSRunningApplication *ra = [NSRunningApplication runningApplicationWithProcessIdentifier:termPid];
            termName = ra.localizedName ?: @"(pid)"; termBundle = ra.bundleIdentifier ?: @"?";
            printf("== target terminal (by pid arg): %s pid=%d bundle=%s ==\n",
                   termName.UTF8String, termPid, termBundle.UTF8String);
        } else {
            NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
            termPid = front.processIdentifier;
            printf("== frontmost terminal: %s pid=%d bundle=%s ==\n",
                   front.localizedName.UTF8String, termPid, front.bundleIdentifier.UTF8String);
        }

        AXUIElementRef appEl = AXUIElementCreateApplication(termPid);
        CFTypeRef win = NULL;
        if (AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute, &win) == kAXSuccess && win) {
            printf("\n-- focused window: ALL attribute names --\n");
            CFArrayRef names = NULL;
            if (AXUIElementCopyAttributeNames((AXUIElementRef)win, &names) == kAXSuccess && names) {
                for (CFIndex i = 0; i < CFArrayGetCount(names); i++)
                    printf("  win.attr: %s\n", [(__bridge NSString *)CFArrayGetValueAtIndex(names, i) UTF8String]);
                CFRelease(names);
            }
            CFRelease(win);
        } else {
            printf("NO AXFocusedWindow exposed\n");
        }
        CFTypeRef focusedEl = NULL;
        if (AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute, &focusedEl) == kAXSuccess && focusedEl) {
            printf("\n-- AXFocusedUIElement: ALL attribute names + values --\n");
            CFArrayRef names = NULL;
            if (AXUIElementCopyAttributeNames((AXUIElementRef)focusedEl, &names) == kAXSuccess && names) {
                for (CFIndex i = 0; i < CFArrayGetCount(names); i++) {
                    NSString *an = (__bridge NSString *)CFArrayGetValueAtIndex(names, i);
                    if ([an isEqualToString:@"AXValue"]) { printf("  el.attr: %s = <pane text, omitted>\n", an.UTF8String); continue; }
                    NSString *v = axStr((AXUIElementRef)focusedEl, (__bridge CFStringRef)an);
                    printf("  el.attr: %s = %.80s\n", an.UTF8String, v ? v.UTF8String : "(nil)");
                }
                CFRelease(names);
            }
            CFRelease(focusedEl);
        }
        CFRelease(appEl);

        // Process tree: find all descendants of the terminal PID.
        NSArray<NSValue*> *procs = allProcs();
        NSMutableDictionary<NSNumber*, NSValue*> *byPid = [NSMutableDictionary dictionary];
        for (NSValue *v in procs) { Proc p = unwrap(v); byPid[@(p.pid)] = v; }

        // descendant set
        NSMutableSet<NSNumber*> *desc = [NSMutableSet set];
        BOOL changed = YES;
        [desc addObject:@(termPid)];
        while (changed) {
            changed = NO;
            for (NSValue *v in procs) {
                Proc p = unwrap(v);
                if ([desc containsObject:@(p.ppid)] && ![desc containsObject:@(p.pid)]) {
                    [desc addObject:@(p.pid)]; changed = YES;
                }
            }
        }

        // TTYs used by descendants and their foreground pgrp.
        printf("\n-- descendant processes with a controlling TTY --\n");
        NSMutableSet<NSNumber*> *ttys = [NSMutableSet set];
        for (NSValue *v in procs) {
            Proc p = unwrap(v);
            if (![desc containsObject:@(p.pid)]) continue;
            if (p.tdev == (dev_t)-1 || p.tdev == 0) continue;
            [ttys addObject:@(p.tdev)];
            printf("pid=%d ppid=%d pgid=%d comm=%-18s tdev=0x%x tpgid=%d\n",
                   p.pid, p.ppid, p.pgid, p.comm, (unsigned)p.tdev, p.tpgid);
        }

        printf("\n-- TTY -> foreground process (tpgid owner) --\n");
        for (NSNumber *td in ttys) {
            dev_t tdev = (dev_t)td.integerValue;
            // find any descendant on this tty to read tpgid
            pid_t tpgid = -1;
            for (NSValue *v in procs) { Proc p = unwrap(v); if (p.tdev == tdev && [desc containsObject:@(p.pid)]) { tpgid = p.tpgid; break; } }
            // foreground process = the process whose pid == tpgid (pgrp leader), prefer an agent
            NSString *fgcomm = @"?"; pid_t fgpid = -1;
            NSMutableArray *members = [NSMutableArray array];
            for (NSValue *v in procs) {
                Proc p = unwrap(v);
                if (p.pgid == tpgid) {
                    [members addObject:[NSString stringWithFormat:@"%d:%s", p.pid, p.comm]];
                    if (p.pid == tpgid) { fgpid = p.pid; fgcomm = [NSString stringWithUTF8String:p.comm]; }
                }
            }
            char ttyname[128] = {0};
            // best-effort device name
            snprintf(ttyname, sizeof(ttyname), "0x%x", (unsigned)tdev);
            printf("tdev=%s tpgid=%d fg_leader=%d(%s) pgrp_members=[%s]\n",
                   ttyname, tpgid, fgpid, fgcomm.UTF8String,
                   [[members componentsJoinedByString:@" "] UTF8String]);
        }

        // For each LOCAL foreground agent (pid==tpgid leader, comm claude/codex/node),
        // resolve its cwd — the join key against the focused pane's status line.
        printf("\n-- foreground local agents with cwd (candidate join key) --\n");
        for (NSNumber *td in ttys) {
            dev_t tdev = (dev_t)td.integerValue;
            pid_t tpgid = -1;
            for (NSValue *v in procs) { Proc p = unwrap(v); if (p.tdev == tdev && [desc containsObject:@(p.pid)]) { tpgid = p.tpgid; break; } }
            // the fg process = the leader whose pid == tpgid
            for (NSValue *v in procs) {
                Proc p = unwrap(v);
                if (p.pid != tpgid) continue;
                struct proc_vnodepathinfo vpi;
                int r = proc_pidinfo(p.pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
                char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
                proc_pidpath(p.pid, path, sizeof(path));
                unsigned int major = (tdev >> 24) & 0xff, minor = tdev & 0xffffff;
                printf("tty=/dev/ttys%03u fg_leader_pid=%d comm=%s cwd=%s image=%s\n",
                       minor, p.pid, p.comm,
                       (r > 0 ? vpi.pvi_cdir.vip_path : "(cwd?)"),
                       path);
            }
        }

        printf("\n-- summary --\n");
        printf("descendant_tty_count=%lu (1 => degenerate single-session attribution is trivially safe)\n",
               (unsigned long)ttys.count);
    }
    return 0;
}
