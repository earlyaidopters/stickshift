// Machine-parsable reason codes for every refusal / non-success outcome (PLAN item 18).
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ShiftReason) {
    ShiftOK = 0,
    // outcomes
    ShiftChanged, ShiftAlreadySet, ShiftUnchanged, ShiftUnknownFinalState, ShiftDialogOpen,
    // refusals
    ShiftNotTerminal, ShiftUnqualifiedTerminal, ShiftNoAgent, ShiftRemoteSession,
    ShiftAmbiguousAgent, ShiftUnsupportedAgentVersion, ShiftBusy, ShiftDraftPresent,
    ShiftSecureInput, ShiftAmbiguousWindow, ShiftNoPermission, ShiftUnsupportedEffort,
    ShiftBadConfig, ShiftLocked, ShiftSelfTarget, ShiftStaleFrame, ShiftUnverifiable,
    ShiftNoFocusedWindow, ShiftInjectDropped, ShiftKeyFocusElsewhere,
};

static inline NSString *ShiftReasonCode(ShiftReason r) {
    switch (r) {
        case ShiftOK: return @"OK";
        case ShiftChanged: return @"CHANGED";
        case ShiftAlreadySet: return @"ALREADY_SET";
        case ShiftUnchanged: return @"UNCHANGED";
        case ShiftUnknownFinalState: return @"UNKNOWN_FINAL_STATE";
        case ShiftDialogOpen: return @"DIALOG_OPEN";
        case ShiftNotTerminal: return @"NOT_TERMINAL";
        case ShiftUnqualifiedTerminal: return @"UNQUALIFIED_TERMINAL";
        case ShiftNoAgent: return @"NO_AGENT";
        case ShiftRemoteSession: return @"REMOTE_SESSION";
        case ShiftAmbiguousAgent: return @"AMBIGUOUS_AGENT";
        case ShiftUnsupportedAgentVersion: return @"UNSUPPORTED_AGENT_VERSION";
        case ShiftBusy: return @"BUSY";
        case ShiftDraftPresent: return @"DRAFT_PRESENT";
        case ShiftSecureInput: return @"SECURE_INPUT";
        case ShiftAmbiguousWindow: return @"AMBIGUOUS_WINDOW";
        case ShiftNoPermission: return @"NO_PERMISSION";
        case ShiftUnsupportedEffort: return @"UNSUPPORTED_EFFORT";
        case ShiftBadConfig: return @"BAD_CONFIG";
        case ShiftLocked: return @"LOCKED";
        case ShiftSelfTarget: return @"SELF_TARGET";
        case ShiftStaleFrame: return @"STALE_FRAME";
        case ShiftUnverifiable: return @"UNVERIFIABLE";
        case ShiftNoFocusedWindow: return @"NO_FOCUSED_WINDOW";
        case ShiftInjectDropped: return @"INJECT_DROPPED";
        case ShiftKeyFocusElsewhere: return @"KEY_FOCUS_ELSEWHERE";
    }
    return @"UNKNOWN";
}
