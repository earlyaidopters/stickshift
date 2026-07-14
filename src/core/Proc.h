#import <Foundation/Foundation.h>

// One process row from the sysctl(KERN_PROC_ALL) snapshot + derived facts.
@interface ProcRow : NSObject
@property(nonatomic) pid_t pid;
@property(nonatomic) pid_t ppid;
@property(nonatomic) pid_t pgid;
@property(nonatomic) dev_t tdev;      // controlling tty device (or 0/-1)
@property(nonatomic) pid_t tpgid;     // tty foreground process group
@property(nonatomic) uint64_t startSec; // process start time (attribution tuple)
@property(nonatomic, copy) NSString *comm;
@property(nonatomic, copy) NSString *cwd;    // resolved lazily
@property(nonatomic, copy) NSString *image;  // executable path, resolved lazily
@end

@interface ProcTable : NSObject
@property(nonatomic, strong) NSArray<ProcRow*> *rows;
+ (instancetype)snapshot;
- (ProcRow *)rowForPid:(pid_t)pid;
// All descendant pids of root (inclusive).
- (NSSet<NSNumber*> *)descendantsOf:(pid_t)root;
// The foreground pgrp-leader process for a tty device (pid == tpgid), or nil.
- (ProcRow *)foregroundLeaderForTdev:(dev_t)tdev amongDescendants:(NSSet<NSNumber*>*)desc;
// Resolve cwd + image path for a row (fills the properties).
- (void)resolvePathsFor:(ProcRow *)row;
+ (NSString *)ttyNameForDev:(dev_t)tdev; // "/dev/ttys030"
@end
