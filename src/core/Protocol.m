#import "Protocol.h"

@implementation PlanStep @end
@implementation SwitchPlan @end

@implementation ShiftProtocol

// Status-line display name (what "📂 … · <Model>" shows) — used for verification and
// the no-op check. NOT the longer "(1M context) (default)" form that only the printed
// "Set model to …" line uses.
+ (NSString *)claudeDisplayForToken:(NSString *)token {
    NSDictionary *m = @{
        @"default": @"Opus 4.8",
        @"opus": @"Opus 4.8",
        @"sonnet": @"Sonnet 5",
        @"haiku": @"Haiku 4.5",
        @"fable": @"Fable 5",
    };
    return m[token.lowercaseString] ?: token;
}

static PlanStep *S(StepKind k, NSString *t, NSString *note) {
    PlanStep *s = [PlanStep new]; s.kind = k; s.text = t; s.note = note; return s;
}

// Codex model picker order (spike 7). Effort order per model (sol has ultra).
static int codexModelRow(NSString *model) {
    NSArray *order = @[@"gpt-5.6-sol", @"gpt-5.6-terra", @"gpt-5.6-luna", @"gpt-5.5", @"gpt-5.4", @"gpt-5.4-mini"];
    NSUInteger i = [order indexOfObject:model];
    return i == NSNotFound ? -1 : (int)(i + 1);
}
static int codexEffortRow(NSString *effort) {
    NSArray *order = @[@"low", @"medium", @"high", @"xhigh", @"max", @"ultra"];
    NSUInteger i = [order indexOfObject:effort];
    return i == NSNotFound ? -1 : (int)(i + 1);
}
// Codex reasoning-picker DISPLAY for an effort token (xhigh renders "Extra high").
static NSString *codexEffortDisplay(NSString *effort) {
    if ([effort isEqualToString:@"xhigh"]) return @"Extra high";
    if (effort.length) return [[effort substringToIndex:1].uppercaseString stringByAppendingString:[effort substringFromIndex:1]];
    return effort;
}

+ (SwitchPlan *)planForKind:(AgentKind)kind tuple:(GearTuple *)tuple {
    return [self planForKind:kind tuple:tuple currentModelDisplay:nil];
}

+ (SwitchPlan *)planForKind:(AgentKind)kind tuple:(GearTuple *)tuple currentModelDisplay:(NSString *)currentModelDisplay {
    if (!tuple.model.length) return nil;
    if (![Config isInjectionSafe:tuple.model]) return nil;
    if (tuple.effort && ![Config isInjectionSafe:tuple.effort]) return nil;

    SwitchPlan *p = [SwitchPlan new];
    NSMutableArray *steps = [NSMutableArray array];

    if (kind == AgentClaude) {
        NSString *disp = [self claudeDisplayForToken:tuple.model];
        // Effort-only shift: the pane already shows the target model, so /model would
        // be a no-op whose wait matches instantly on the pre-existing status line.
        BOOL effortOnly = tuple.effort && currentModelDisplay && [currentModelDisplay isEqualToString:disp];
        if (!effortOnly) {
            [steps addObject:S(StepTypeText, [@"/model " stringByAppendingString:tuple.model], @"type /model <token>")];
            [steps addObject:S(StepReturn, nil, @"submit model")];
            PlanStep *mw = S(StepWaitState, @"Set model to", @"await model applied (handles Switch-model? dialog)");
            mw.expectModel = disp; mw.handlesDialog = YES;   // status line verifies; dialog auto-handled
            [steps addObject:mw];
        }
        if (tuple.effort) {
            [steps addObject:S(StepTypeText, [@"/effort " stringByAppendingString:tuple.effort], @"type /effort <level>")];
            [steps addObject:S(StepReturn, nil, @"submit effort")];
            PlanStep *ew = S(StepWaitState, @"Set effort level to", @"await effort applied (handles Change-effort-level? dialog)");
            ew.expectEffort = tuple.effort;
            ew.handlesDialog = YES;   // mid-conversation "Change effort level?" confirm
            [steps addObject:ew];
        }
        p.expectedModelDisplay = disp;
        p.expectedEffort = tuple.effort;
        p.evidenceNeedles = effortOnly
            ? @[[@"Set effort level to " stringByAppendingString:tuple.effort],
                [NSString stringWithFormat:@"%@ · /effort", tuple.effort]]   // the ◉/○ chip
            : @[[@"Set model to " stringByAppendingString:disp],
                [NSString stringWithFormat:@"· %@", disp]]; // status line too
        p.summary = effortOnly
            ? [NSString stringWithFormat:@"claude: /effort %@ (already %@)", tuple.effort, disp]
            : [NSString stringWithFormat:@"claude: /model %@%@", tuple.model,
                     tuple.effort ? [@" + /effort " stringByAppendingString:tuple.effort] : @""];
    } else if (kind == AgentCodex) {
        int mRow = codexModelRow(tuple.model);
        int eRow = tuple.effort ? codexEffortRow(tuple.effort) : -1;
        if (mRow < 0) return nil;
        (void)mRow; (void)eRow;
        [steps addObject:S(StepTypeText, @"/model", @"type /model")];
        [steps addObject:S(StepReturn, nil, @"open popup")];
        [steps addObject:S(StepWaitState, @"Select Model and Effort", @"await model picker")];
        // Press the VERIFIED row: read the live picker, find the row with this model's
        // label, press it. A reordered/absent model refuses instead of mis-selecting.
        [steps addObject:S(StepCodexSelect, tuple.model, ([NSString stringWithFormat:@"select model row for %@ (label-verified)", tuple.model]))];
        if (tuple.effort) {
            [steps addObject:S(StepWaitState, @"Select Reasoning Level", @"await effort stage")];
            [steps addObject:S(StepCodexSelect, codexEffortDisplay(tuple.effort), ([NSString stringWithFormat:@"select effort row for %@ (label-verified)", tuple.effort]))];
        } else {
            [steps addObject:S(StepReturn, nil, @"confirm current effort")];
        }
        [steps addObject:S(StepWaitState, @"Model changed to", @"await confirmation")];
        p.expectedModelDisplay = tuple.model;
        p.expectedEffort = tuple.effort;
        p.evidenceNeedles = @[[NSString stringWithFormat:@"Model changed to %@", tuple.model],
                              [NSString stringWithFormat:@"%@ %@ · /", tuple.model, tuple.effort ?: @""]];
        p.summary = [NSString stringWithFormat:@"codex picker: model row %d (%@)%@", mRow, tuple.model,
                     eRow>0 ? [NSString stringWithFormat:@", effort row %d (%@)", eRow, tuple.effort] : @""];
    } else {
        return nil;
    }
    p.steps = steps;
    return p;
}

@end
