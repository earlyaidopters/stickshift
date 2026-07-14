#import "Proc.h"
#import <libproc.h>
#import <sys/sysctl.h>
#import <sys/proc_info.h>

@implementation ProcRow @end

@implementation ProcTable

+ (instancetype)snapshot {
    ProcTable *t = [ProcTable new];
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) { t.rows = @[]; return t; }
    struct kinfo_proc *buf = malloc(len);
    if (sysctl(mib, 4, buf, &len, NULL, 0) != 0) { free(buf); t.rows = @[]; return t; }
    int count = (int)(len / sizeof(struct kinfo_proc));
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:count];
    for (int i = 0; i < count; i++) {
        ProcRow *r = [ProcRow new];
        r.pid = buf[i].kp_proc.p_pid;
        r.ppid = buf[i].kp_eproc.e_ppid;
        r.pgid = buf[i].kp_eproc.e_pgid;
        r.tdev = buf[i].kp_eproc.e_tdev;
        r.tpgid = buf[i].kp_eproc.e_tpgid;
        r.startSec = (uint64_t)buf[i].kp_proc.p_starttime.tv_sec;
        r.comm = [NSString stringWithUTF8String:buf[i].kp_proc.p_comm] ?: @"";
        [rows addObject:r];
    }
    free(buf);
    t.rows = rows;
    return t;
}

- (ProcRow *)rowForPid:(pid_t)pid {
    for (ProcRow *r in self.rows) if (r.pid == pid) return r;
    return nil;
}

- (NSSet<NSNumber*> *)descendantsOf:(pid_t)root {
    NSMutableDictionary<NSNumber*, NSMutableArray<NSNumber*>*> *kids = [NSMutableDictionary dictionary];
    for (ProcRow *r in self.rows) {
        NSNumber *pp = @(r.ppid);
        if (!kids[pp]) kids[pp] = [NSMutableArray array];
        [kids[pp] addObject:@(r.pid)];
    }
    NSMutableSet *out = [NSMutableSet setWithObject:@(root)];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:@(root)];
    while (stack.count) {
        NSNumber *cur = stack.lastObject; [stack removeLastObject];
        for (NSNumber *k in kids[cur] ?: @[]) {
            if (![out containsObject:k]) { [out addObject:k]; [stack addObject:k]; }
        }
    }
    return out;
}

- (ProcRow *)foregroundLeaderForTdev:(dev_t)tdev amongDescendants:(NSSet<NSNumber*>*)desc {
    // find tpgid for this tty from any descendant on it
    pid_t tpgid = -1;
    for (ProcRow *r in self.rows) {
        if (r.tdev == tdev && [desc containsObject:@(r.pid)]) { tpgid = r.tpgid; break; }
    }
    if (tpgid < 0) return nil;
    for (ProcRow *r in self.rows) if (r.pid == tpgid) return r;
    return nil;
}

- (void)resolvePathsFor:(ProcRow *)row {
    if (!row) return;
    struct proc_vnodepathinfo vpi;
    int r = proc_pidinfo(row.pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
    if (r > 0) row.cwd = [NSString stringWithUTF8String:vpi.pvi_cdir.vip_path];
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(row.pid, path, sizeof(path)) > 0) row.image = [NSString stringWithUTF8String:path];
}

+ (NSString *)ttyNameForDev:(dev_t)tdev {
    unsigned minor = (unsigned)(tdev & 0xffffff);
    return [NSString stringWithFormat:@"/dev/ttys%03u", minor];
}

@end
