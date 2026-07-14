#import <Foundation/Foundation.h>
#import "AXState.h"
#import "Config.h"

// A single injection step in a switch plan.
typedef NS_ENUM(NSInteger, StepKind) {
    StepTypeText, StepReturn, StepEscape, StepDigit, StepDown, StepUp,
    StepWaitState,     // wait for expectedContains in pane text
    StepCodexSelect,   // read the codex picker, press the VERIFIED row for step.text label
};

@interface PlanStep : NSObject
@property(nonatomic) StepKind kind;
@property(nonatomic, copy) NSString *text;            // for TypeText / WaitState needle
@property(nonatomic) int digit;                       // for Digit
@property(nonatomic, copy) NSString *note;            // human description
// For a WaitState that should verify via the pane's classified status line (Claude),
// and handle the mid-conversation "Switch model?" dialog. nil => plain string wait.
@property(nonatomic, copy) NSString *expectModel;     // expected status-line model display
@property(nonatomic, copy) NSString *expectEffort;    // expected status-line effort
@property(nonatomic) BOOL handlesDialog;              // this wait may face the switch dialog
@end

@interface SwitchPlan : NSObject
@property(nonatomic, strong) NSArray<PlanStep*> *steps;
@property(nonatomic, copy) NSString *expectedModelDisplay;  // for no-op + verify
@property(nonatomic, copy) NSString *expectedEffort;        // may be nil
@property(nonatomic, copy) NSArray<NSString*> *evidenceNeedles; // any-of, VERIFY
@property(nonatomic, copy) NSString *summary;
@end

@interface ShiftProtocol : NSObject
// Build a plan for (agent kind, gear tuple). Returns nil if unqualified.
+ (SwitchPlan *)planForKind:(AgentKind)kind tuple:(GearTuple *)tuple;
// Same, but aware of the pane's current status-line model display. When the pane is
// already at the target model and the tuple carries an effort, the claude plan skips
// the redundant /model injection and types only /effort (fewer keystrokes, and the
// verify no longer depends on a model transition that will never happen).
+ (SwitchPlan *)planForKind:(AgentKind)kind tuple:(GearTuple *)tuple currentModelDisplay:(NSString *)currentModelDisplay;
// Expected display name for a claude inline model token (sonnet -> "Sonnet 5").
+ (NSString *)claudeDisplayForToken:(NSString *)token;
@end
