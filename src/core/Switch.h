#import <Foundation/Foundation.h>
#import "Reason.h"
#import "Config.h"
#import "Attribution.h"
#import "Protocol.h"

// Privacy-safe append to ~/.stickshift/log (state transitions + reason codes only,
// never pane text). Shared by the CLI and the menu-bar app so BOTH surfaces leave a
// diagnosable trail — panel shifts used to vanish without a trace when they refused.
void StickShiftLogLine(NSString *line);

@interface SwitchOutcome : NSObject
@property(nonatomic) ShiftReason reason;
@property(nonatomic, copy) NSString *stage;    // last state-machine stage reached
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, strong) TargetTuple *target;
@property(nonatomic, strong) SwitchPlan *plan;
@property(nonatomic) BOOL committed;           // did we actually inject?
- (NSString *)describe;
@end

// Per-frame decision for the WATCH/VERIFY loop, extracted so it can be unit-tested
// without live AX or injection (this is the confirm-dialog path that broke live).
typedef NS_ENUM(NSInteger, StepDecision) {
    StepDecWait = 0,     // keep polling
    StepDecMatched,      // success — target state observed
    StepDecConfirm,      // switch dialog present + policy=confirm -> press confirm
    StepDecCancel,       // switch dialog present + policy=cancel -> press cancel
    StepDecDialogOpen,   // switch dialog present + policy=ask -> return DIALOG_OPEN
    StepDecError,        // a known error line appeared
};

@interface Switch : NSObject
// Pure decision from a classified pane (no side effects). `confirmed` = have we already
// pressed confirm this run. Exposed for tests.
+ (StepDecision)decideStep:(PlanStep *)step pane:(PaneState *)p
                 autoAnswer:(BOOL)autoAnswer policy:(DialogPolicy)policy confirmed:(BOOL)confirmed;
// Pure no-op test (ALREADY_SET). nil effort = model-only. Exposed for tests.
+ (BOOL)pane:(PaneState *)pane alreadyAtModel:(NSString *)expectModel effort:(NSString *)expectEffort;
// Last n lines of the pane text — evidence/error needles anchor here so stale
// scrollback can never satisfy (or fail) a live wait. Pure/testable.
+ (NSString *)bottomLines:(NSString *)txt count:(NSUInteger)n;
// Non-overlapping occurrence count; the delivery check requires the typed text's
// count to INCREASE, so an identical command in scrollback can't fake delivery.
+ (NSUInteger)occurrencesOf:(NSString *)needle inText:(NSString *)txt;
// Is the dialog's extracted target OURS? Claude decorates the target with
// parenthesized qualifiers — "Opus 4.8 (1M context) (default)" — so exact equality
// refused our own dialog (live 2026-07-13). Case-insensitive; the expectation must
// be the whole target or a prefix ending at a token boundary (space or "(").
+ (BOOL)dialogTarget:(NSString *)target matchesExpected:(NSString *)expect;
// Full pipeline. If commit==NO, stops after PRECHECK + no-op check and reports the
// plan (dry run) without injecting. invokingTty enables SELF_TARGET detection.
+ (SwitchOutcome *)runGear:(NSString *)gear
                    config:(Config *)cfg
               invokingTty:(NSString *)invokingTty
                    commit:(BOOL)commit
          terminalOverride:(pid_t)terminalOverride; // 0 = frontmost (test hook)

// Switch to an explicit (model token, effort) chosen in the UI.
+ (SwitchOutcome *)runModelToken:(NSString *)modelToken
                          effort:(NSString *)effort
                          config:(Config *)cfg
                     invokingTty:(NSString *)invokingTty
                          commit:(BOOL)commit
                terminalOverride:(pid_t)terminalOverride;
@end
