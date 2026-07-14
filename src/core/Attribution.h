#import <Foundation/Foundation.h>
#import "Reason.h"
#import "AXState.h"
#import "Manifest.h"

// The immutable identity tuple fixed at ATTRIBUTE_PROCESS (PLAN item 12).
@interface TargetTuple : NSObject
@property(nonatomic) pid_t terminalPid;
@property(nonatomic, copy) NSString *windowTitle;
@property(nonatomic) CGRect geometry;
@property(nonatomic) pid_t agentPid;
@property(nonatomic) uint64_t agentStartSec;
@property(nonatomic, copy) NSString *tty;
@property(nonatomic) pid_t foregroundPgrp;
@property(nonatomic, strong) AgentIdentity *identity;
@property(nonatomic, strong) PaneState *pane;   // the state read at attribution
@end

@interface AttributionResult : NSObject
@property(nonatomic) ShiftReason reason;
@property(nonatomic, strong) TargetTuple *target;   // set iff reason==OK
@property(nonatomic, copy) NSString *detail;
@end

@class ProcRow;
@interface Attribution : NSObject
// The signed native `codex` process inside the fg process group (pgid). Sub-agent codex
// processes live in OTHER groups and must be ignored. Returns nil if none. Pure/testable.
+ (ProcRow *)nativeCodexInGroup:(pid_t)pgid rows:(NSArray<ProcRow *> *)rows;
// Match strength between a claude process cwd and the pane's 📂 hint. 0 = no match;
// lower is stronger: 1 = hint is the cwd basename (exact), 2 = hint is an ancestor
// path component of cwd (session nested under a dir named hint), 3 = hint is an
// existing child directory of cwd. Pure/testable.
+ (int)claudeCwdMatchTier:(NSString *)cwd hint:(NSString *)hint;
// Content-anchored attribution for a Warp-style terminal: read focused pane (AX),
// classify agent, then require exactly one LOCAL manifest-qualified agent whose
// cwd+kind match. Fail closed with a reason code otherwise.
+ (AttributionResult *)attributeFocusedTerminal:(pid_t)terminalPid
                                     invokingTty:(NSString *)invokingTty;
@end
