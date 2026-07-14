#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, AgentKind) { AgentUnknown = 0, AgentClaude, AgentCodex };

// Parsed view of the focused terminal pane, derived from AX pane text (Warp) or
// OCR (fallback). Everything needed by the precondition checker.
@interface PaneState : NSObject
@property(nonatomic) BOOL hasFocusedWindow;
@property(nonatomic) pid_t terminalPid;
@property(nonatomic, copy) NSString *windowTitle;
@property(nonatomic) CGRect focusedFrame;      // focused element bounds (screen pts)
@property(nonatomic, copy) NSString *paneText;  // full AX value (may be nil under OCR)
@property(nonatomic) AgentKind agent;
@property(nonatomic, copy) NSString *modelText; // e.g. "Fable 5" / "gpt-5.6-sol"
@property(nonatomic, copy) NSString *effortText;// e.g. "low" (codex footer), may be nil
@property(nonatomic, copy) NSString *cwdHint;   // basename (claude) or full path (codex)
@property(nonatomic) BOOL idle;                 // positive idle-prompt match
@property(nonatomic) BOOL busy;                 // positive busy marker
@property(nonatomic) BOOL inputEmpty;           // provably empty input
@property(nonatomic) BOOL switchDialogOpen;     // Claude "Switch model?" dialog present
@property(nonatomic, copy) NSString *dialogTargetDisplay; // display name inside dialog
@end

@interface AXState : NSObject
// Read the focused pane of a terminal app by pid using AX. Returns a PaneState.
+ (PaneState *)readFocusedPaneForTerminal:(pid_t)terminalPid;
// Read the frontmost app pid (the on-screen terminal the user is looking at).
+ (pid_t)frontmostPid;
+ (NSString *)frontmostBundleId;
// pid owning the element that will RECEIVE keyboard events right now (system-wide AX
// focused element). Distinct from the frontmost app: a non-activating panel can hold
// key focus while another app stays frontmost. -1 if unreadable.
+ (pid_t)keyboardFocusPid;
// Classify agent + state from raw pane text (exposed for OCR fallback + tests).
+ (void)classifyText:(NSString *)text into:(PaneState *)st;
// Find the 1-based row number of a Codex picker option whose label matches `label`
// (case-insensitive prefix, after the "N. " marker). 0 if not present. Used to press a
// VERIFIED row instead of a hardcoded one, so a reordered/absent option refuses.
+ (NSInteger)codexPickerRowFor:(NSString *)label inText:(NSString *)text;
@end
