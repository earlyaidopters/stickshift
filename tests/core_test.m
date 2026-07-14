// Deterministic tests for the parsing + protocol logic, over fixtures built from
// the real spike captures. Exercises the paths that live panes (with the user's drafts
// and focus) can't reproduce on demand.
#import <Foundation/Foundation.h>
#import "AXState.h"
#import "Protocol.h"
#import "Config.h"
#import "Manifest.h"
#import "Switch.h"
#import "Attribution.h"
#import "Proc.h"
#import "Inject.h"

static int failures = 0;
static void check(BOOL cond, NSString *name) {
    printf("  [%s] %s\n", cond ? "PASS" : "FAIL", name.UTF8String);
    if (!cond) failures++;
}

// --- fixtures (verbatim structure from spike captures) ---
static NSString *claudeIdleEmpty(void) {
    return @"⏺ pong\n"
           @"✻ Cooked for 2s\n"
           @"                                                  ◉ xhigh · /effort\n"
           @"────────────────────────────────────────────────────────────────\n"
           @"❯ \n"
           @"────────────────────────────────────────────────────────────────\n"
           @"  📂 demo-site  ·  Fable 5  ▰▰▰▱▱▱ 39%                    /rc\n"
           @"  5h: 41% (resets 18m)  7d: 31% (resets 123h 48m)\n"
           @"  ⏵⏵ bypass permissions on · 1 shell · ← for agents\n";
}
static NSString *claudeDraft(void) {
    return [claudeIdleEmpty() stringByReplacingOccurrencesOfString:@"❯ \n"
                                                        withString:@"❯ build the about page next\n"];
}
static NSString *claudeBusy(void) {
    return @"❯ do the thing\n"
           @"✽ Moonwalking… (3s · ↓ 120 tokens · esc to interrupt)\n"
           @"  📂 demo-site  ·  Fable 5\n";
}
static NSString *claudeDialog(void) {
    return @"⏺ pong\n"
           @"▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔\n"
           @"   Switch model?\n"
           @"   This conversation is cached for the current model. Switching to Opus 4.8 means…\n"
           @"   ❯ 1. Yes, switch to Opus 4.8\n"
           @"     2. No, go back\n";
}
static NSString *codexIdleEmpty(void) {
    return @"• Ready. What would you like to work on?\n"
           @"› Explain this codebase\n"
           @"  gpt-5.6-sol low · /Users/demo/Projects/Effort Demo/codex_high\n";
}
static NSString *codexBusy(void) {
    return @"› analyze this\n"
           @"• Working (2s • esc to interrupt)\n"
           @"  gpt-5.6-sol low · /Users/demo/Desktop/x\n";
}
// Real capture: a running /loop shows a spinner WITHOUT "esc to interrupt", with a
// queued-message placeholder input. Must read as BUSY, not idle. (found live)
static NSString *claudeLoopBusy(void) {
    return @"✳ Fluttering… (10m 12s · ↓ 34.4k tokens)\n"
           @"  ❯ /loop 10m keep testing it\n"
           @"                                            488198 tokens\n"
           @"────────────────────────────────────────────────────────────\n"
           @"❯ Press up to edit queued messages\n"
           @"────────────────────────────────────────────────────────────\n"
           @"  📂 StickShift  ·  Opus 4.8  ▰▰▰▰▱▱ 49%              /rc\n"
           @"  ⏵⏵ bypass permissions on · ← for agents\n";
}
// A pane whose SCROLLBACK discusses the dialog in prose must NOT read as dialog-open,
// and its status-line model must win over a "Set model to X" line in scrollback.
static NSString *claudeProseNotDialog(void) {
    return @"⎿  I explained the Switch model? dialog: Yes, switch to Opus, or No, go back.\n"
           @"⎿  Set model to Haiku 4.5 and saved as your default for new sessions\n"
           @"❯ \n"
           @"────────────────────────────────────────────────────────────\n"
           @"  📂 proj  ·  Fable 5  ▰▰▱▱ 20%              /rc\n";
}

int main(void) {
    @autoreleasepool {
        printf("== classifier ==\n");
        PaneState *a = [PaneState new]; [AXState classifyText:claudeIdleEmpty() into:a];
        check(a.agent == AgentClaude, @"claude idle: agent=claude");
        check([a.modelText isEqualToString:@"Fable 5"], @"claude idle: model=Fable 5");
        check([a.effortText isEqualToString:@"xhigh"], @"claude idle: effort=xhigh");
        check([a.cwdHint isEqualToString:@"demo-site"], @"claude idle: cwd hint");
        check(a.idle, @"claude idle: idle=YES");
        check(a.inputEmpty, @"claude idle: inputEmpty=YES");
        check(!a.busy, @"claude idle: busy=NO");

        PaneState *d = [PaneState new]; [AXState classifyText:claudeDraft() into:d];
        check(!d.inputEmpty, @"claude draft: inputEmpty=NO (DRAFT_PRESENT)");

        PaneState *b = [PaneState new]; [AXState classifyText:claudeBusy() into:b];
        check(b.busy, @"claude busy: busy=YES");
        check(!b.idle, @"claude busy: idle=NO");

        PaneState *dlg = [PaneState new]; [AXState classifyText:claudeDialog() into:dlg];
        check(dlg.switchDialogOpen, @"claude dialog: switchDialogOpen=YES");
        check([dlg.dialogTargetDisplay isEqualToString:@"Opus 4.8"], @"claude dialog: target=Opus 4.8");
        // While a dialog is up Claude hides the status line + composer, so every normal
        // agent marker is gone — the dialog itself must count as Claude chrome, else
        // revalidation reads AgentUnknown and refuses to answer our own dialog (live).
        check(dlg.agent == AgentClaude, @"claude dialog: dialog chrome alone classifies agent=claude");

        // The EFFORT confirm dialog (live capture 2026-07-13: appears mid-conversation
        // because the cached history gets re-read at the new effort level).
        NSString *effDialog =
          @"  Change effort level?\n"
          @"  Your next response will be slower and use more tokens\n"
          @"\n"
          @"  This conversation is cached for the current effort level. Switching to high\n"
          @"  means the full history gets re-read on your next message.\n"
          @"\n"
          @"❯ 1. Yes, switch to high\n"
          @"  2. No, go back\n";
        PaneState *edlg = [PaneState new]; [AXState classifyText:effDialog into:edlg];
        check(edlg.switchDialogOpen, @"effort dialog: switchDialogOpen=YES");
        check([edlg.dialogTargetDisplay isEqualToString:@"high"], @"effort dialog: target=high");

        PaneState *c = [PaneState new]; [AXState classifyText:codexIdleEmpty() into:c];
        check(c.agent == AgentCodex, @"codex idle: agent=codex");
        check([c.modelText isEqualToString:@"gpt-5.6-sol"], @"codex idle: model");
        check([c.effortText isEqualToString:@"low"], @"codex idle: effort=low");
        check([c.cwdHint hasSuffix:@"codex_high"], @"codex idle: cwd full path");
        check(c.inputEmpty, @"codex idle: placeholder => inputEmpty=YES");

        PaneState *cb = [PaneState new]; [AXState classifyText:codexBusy() into:cb];
        check(cb.busy, @"codex busy: busy=YES");

        // Current codex footer (live 2026-07-13): plain-space separator, ~-abbreviated
        // path — the old "· /path" regex missed it entirely (no model, no cwd hint).
        NSString *codexTilde =
          @">_ OpenAI Codex (v0.87.0)\n"
          @"› Run /review on my current changes\n"
          @"  gpt-5.6-sol low      ~/Projects/Demo Course\n";
        PaneState *ct = [PaneState new]; [AXState classifyText:codexTilde into:ct];
        check(ct.agent == AgentCodex, @"codex tilde footer: agent=codex");
        check([ct.modelText isEqualToString:@"gpt-5.6-sol"], @"codex tilde footer: model parsed");
        check([ct.effortText isEqualToString:@"low"], @"codex tilde footer: effort parsed");
        check([ct.cwdHint isEqualToString:[NSHomeDirectory() stringByAppendingString:
              @"/Projects/Demo Course"]],
              @"codex tilde footer: cwd hint expanded to absolute path");
        // 'extra high' must win over its 'high' substring
        NSString *codexXhigh = @"› x\n  gpt-5.6-terra extra high · /Users/x/proj\n";
        PaneState *cx = [PaneState new]; [AXState classifyText:codexXhigh into:cx];
        check([cx.effortText isEqualToString:@"extra high"], @"codex effort 'extra high' parsed whole");
        // banner scrolled away: the tilde footer alone must still classify as codex
        NSString *codexNoBanner = @"› Explain this\n  gpt-5.6-sol low      ~/Desktop/x\n";
        PaneState *cnb = [PaneState new]; [AXState classifyText:codexNoBanner into:cnb];
        check(cnb.agent == AgentCodex, @"codex tilde footer without banner: agent=codex");
        // HINT-BAR footer (live 2026-07-13): the path slot shows command help. The
        // hint text must NOT become the cwd hint (it attributed to nothing), but
        // model + effort still parse from the same line.
        NSString *codexHintBar = @"› Run /review\n  gpt-5.6-sol low   /model to change | /approvals to adjust\n";
        PaneState *chb = [PaneState new]; [AXState classifyText:codexHintBar into:chb];
        check(chb.agent == AgentCodex, @"codex hint-bar footer: agent=codex");
        check([chb.modelText isEqualToString:@"gpt-5.6-sol"], @"codex hint-bar footer: model still parsed");
        check([chb.effortText isEqualToString:@"low"], @"codex hint-bar footer: effort still parsed");
        check(chb.cwdHint.length == 0, @"codex hint-bar footer: '/model to change |' is NOT a cwd hint");
        // banner "directory:" line rescues the cwd when the footer is in hint mode
        NSString *codexBannerDir =
          @">_ OpenAI Codex (v0.87.0)\n  directory:   ~/Desktop/Proj X\n"
          @"› x\n  gpt-5.6-sol low   /model to change | /approvals\n";
        PaneState *cbd = [PaneState new]; [AXState classifyText:codexBannerDir into:cbd];
        check([cbd.cwdHint isEqualToString:[NSHomeDirectory() stringByAppendingString:@"/Desktop/Proj X"]],
              @"codex banner directory: fallback cwd hint, ~ expanded");
        // Every ghost suggestion in codex 0.144.1's rotation must read as EMPTY input
        // (live 2026-07-13: "Run /review on my current changes" -> DRAFT_PRESENT).
        {
            NSArray *rotation = @[@"Explain this codebase", @"Summarize recent commits",
                @"Implement {feature}", @"Find and fix a bug in @filename",
                @"Write tests for @filename", @"Improve documentation in @filename",
                @"Run /review on my current changes", @"Use /skills to list available skills",
                @"Check recently modified functions for compatibility",
                @"How many files have been modified?", @"Will this algorithm scale well?"];
            BOOL allEmpty = YES; NSString *badPh = nil;
            for (NSString *ph in rotation) {
                NSString *txt = [NSString stringWithFormat:@"› %@\n  gpt-5.6-sol low   /model to change | /x\n", ph];
                PaneState *pp = [PaneState new]; [AXState classifyText:txt into:pp];
                if (!pp.inputEmpty) { allEmpty = NO; badPh = ph; break; }
            }
            check(allEmpty, allEmpty ? @"all 11 codex ghost suggestions read as empty input"
                                     : [NSString stringWithFormat:@"suggestion read as draft: %@", badPh]);
            // an actual user draft must still refuse
            PaneState *pd = [PaneState new];
            [AXState classifyText:@"› fix the login bug please\n  gpt-5.6-sol low   /model to change | /x\n" into:pd];
            check(!pd.inputEmpty, @"a real codex draft still reads as DRAFT_PRESENT");
        }
        // a truncated banner path ("…") must be rejected, not half-matched
        NSString *codexBannerTrunc = @"  directory:   ~/Desktop/Early AI-dopt…rse\n› x\n  gpt-5.6-sol low   /model to change | /x\n";
        PaneState *cbt = [PaneState new]; [AXState classifyText:codexBannerTrunc into:cbt];
        check(cbt.cwdHint.length == 0, @"truncated banner path is rejected (no bogus hint)");

        // Regression: real cases found found in live testing
        PaneState *lb = [PaneState new]; [AXState classifyText:claudeLoopBusy() into:lb];
        check(lb.busy, @"loop spinner (no 'esc to interrupt'): busy=YES");
        check(!lb.idle, @"loop spinner: idle=NO (won't switch a working pane)");
        check([lb.modelText isEqualToString:@"Opus 4.8"], @"loop pane: model from status line = Opus 4.8");
        check(lb.inputEmpty, @"queued-messages placeholder: inputEmpty=YES");

        PaneState *pr = [PaneState new]; [AXState classifyText:claudeProseNotDialog() into:pr];
        check(!pr.switchDialogOpen, @"prose mentioning dialog: switchDialogOpen=NO (no false trigger)");
        check([pr.modelText isEqualToString:@"Fable 5"], @"status line wins over 'Set model to' in scrollback");
        check(pr.idle, @"prose pane: idle=YES");
        check(pr.inputEmpty, @"prose pane: empty prompt = inputEmpty=YES");

        printf("\n== protocol plans ==\n");
        GearTuple *g4 = [GearTuple new]; g4.model = @"fable"; g4.effort = @"high";
        SwitchPlan *p4 = [ShiftProtocol planForKind:AgentClaude tuple:g4];
        check(p4 != nil, @"claude fable+high: plan built");
        check([p4.expectedModelDisplay isEqualToString:@"Fable 5"], @"claude plan: expected display Fable 5");
        check(p4.steps.count == 6, @"claude plan: 6 steps (model+effort)");
        check([p4.evidenceNeedles.firstObject containsString:@"Set model to Fable 5"], @"claude plan: evidence needle");

        // Effort-only shift: pane already at the target model -> skip /model entirely
        GearTuple *ge = [GearTuple new]; ge.model = @"fable"; ge.effort = @"max";
        SwitchPlan *pe = [ShiftProtocol planForKind:AgentClaude tuple:ge currentModelDisplay:@"Fable 5"];
        check(pe.steps.count == 3, @"claude effort-only: 3 steps (no /model when pane already at model)");
        check(((PlanStep *)pe.steps.firstObject).kind == StepTypeText
              && [((PlanStep *)pe.steps.firstObject).text isEqualToString:@"/effort max"],
              @"claude effort-only: first step types /effort max");
        check([pe.evidenceNeedles.firstObject isEqualToString:@"Set effort level to max"],
              @"claude effort-only: evidence is the effort line, not the model line");
        SwitchPlan *pe2 = [ShiftProtocol planForKind:AgentClaude tuple:ge currentModelDisplay:@"Opus 4.8"];
        check(pe2.steps.count == 6, @"claude different current model: full model+effort plan");
        SwitchPlan *pe3 = [ShiftProtocol planForKind:AgentClaude tuple:ge currentModelDisplay:nil];
        check(pe3.steps.count == 6, @"claude unknown current model: full plan (fail safe)");
        check(((PlanStep *)pe.steps.lastObject).handlesDialog,
              @"claude effort wait handles the Change-effort-level? dialog");

        printf("\n== config: persist switch-dialog policy ==\n");
        {
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"ss-test-%d.toml", getpid()]];
            setenv("STICKSHIFT_CONFIG", tmp.fileSystemRepresentation, 1);
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            // seed a file with an unrelated line that must survive the upsert
            [@"# my config\nenabled_terminals = [\"dev.warp.Warp-Stable\"]\n"
                writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@(0600)} ofItemAtPath:tmp error:nil];
            Config *pc = [Config defaults];
            pc.dialogPolicy = DialogConfirm; pc.autoAnswerEnabled = YES;
            NSString *perr = nil;
            check([pc persistPolicy:&perr], @"persistPolicy writes without error");
            Config *rc = [Config load];
            check(rc.dialogPolicy == DialogConfirm && rc.autoAnswerEnabled,
                  @"reloaded config has confirm + auto_answer");
            NSString *body = [NSString stringWithContentsOfFile:tmp encoding:NSUTF8StringEncoding error:nil];
            check([body containsString:@"# my config"], @"unrelated lines survive the upsert");
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            unsetenv("STICKSHIFT_CONFIG");
        }

        GearTuple *gc = [GearTuple new]; gc.model = @"gpt-5.6-luna"; gc.effort = @"xhigh";
        SwitchPlan *pc = [ShiftProtocol planForKind:AgentCodex tuple:gc];
        check(pc != nil, @"codex luna+xhigh: plan built");
        // label-verified selects: one for the model, one for the effort DISPLAY
        BOOL selModel = NO, selEffort = NO;
        for (PlanStep *s in pc.steps) {
            if (s.kind == StepCodexSelect && [s.text isEqualToString:@"gpt-5.6-luna"]) selModel = YES;
            if (s.kind == StepCodexSelect && [s.text isEqualToString:@"Extra high"]) selEffort = YES;
        }
        check(selModel, @"codex plan: model select is label-verified (gpt-5.6-luna)");
        check(selEffort, @"codex plan: effort select uses picker display 'Extra high' for xhigh");

        // Picker-row parser against the REAL captured picker text (spike 7)
        NSString *modelPicker =
          @"  Select Model and Effort\n"
          @"  Access legacy models by running codex -m <model_name>\n"
          @"› 1. gpt-5.6-sol (current)  Latest frontier agentic coding model.\n"
          @"  2. gpt-5.6-terra          Balanced agentic coding model for everyday work.\n"
          @"  3. gpt-5.6-luna           Fast and affordable agentic coding model.\n"
          @"  4. gpt-5.5                Frontier model...\n"
          @"  5. gpt-5.4                Strong model...\n"
          @"  6. gpt-5.4-mini           Small, fast...\n";
        check([AXState codexPickerRowFor:@"gpt-5.6-luna" inText:modelPicker] == 3, @"picker: luna -> row 3");
        check([AXState codexPickerRowFor:@"gpt-5.6-sol" inText:modelPicker] == 1, @"picker: sol -> row 1");
        check([AXState codexPickerRowFor:@"gpt-5.4-mini" inText:modelPicker] == 6, @"picker: 5.4-mini -> row 6");
        check([AXState codexPickerRowFor:@"gpt-9.9-nope" inText:modelPicker] == 0, @"picker: absent model -> 0 (refuse)");
        NSString *effortPicker =
          @"  Select Reasoning Level for gpt-5.6-sol\n"
          @"› 1. Low (current)     Fast responses...\n"
          @"  2. Medium (default)  Balances...\n"
          @"  3. High              Greater...\n"
          @"  4. Extra high        Extra high reasoning...\n"
          @"  5. Max               Maximum...\n"
          @"  6. Ultra             Maximum reasoning with delegation...\n";
        check([AXState codexPickerRowFor:@"Extra high" inText:effortPicker] == 4, @"picker: Extra high -> row 4");
        check([AXState codexPickerRowFor:@"Ultra" inText:effortPicker] == 6, @"picker: Ultra -> row 6");
        check([AXState codexPickerRowFor:@"Ultra" inText:modelPicker] == 0, @"picker: Ultra not in model list -> 0");
        // Token boundary (Codex #8): with gpt-5.4-mini listed BEFORE gpt-5.4, a prefix
        // match would select mini for a gpt-5.4 request and inject the wrong model.
        NSString *miniFirstPicker =
          @"› 1. gpt-5.4-mini  Small, fast...\n"
          @"  2. gpt-5.4       Strong model...\n";
        check([AXState codexPickerRowFor:@"gpt-5.4" inText:miniFirstPicker] == 2,
              @"picker boundary: gpt-5.4 -> row 2 (never mini's row 1)");
        check([AXState codexPickerRowFor:@"gpt-5.4-mini" inText:miniFirstPicker] == 1,
              @"picker boundary: gpt-5.4-mini -> row 1");

        printf("\n== bottomLines / occurrencesOf (delivery + scrollback anchors) ==\n");
        check([[Switch bottomLines:@"a\nb\nc\nd" count:2] isEqualToString:@"c\nd"],
              @"bottomLines: last 2 of 4");
        check([[Switch bottomLines:@"a\nb" count:10] isEqualToString:@"a\nb"],
              @"bottomLines: n larger than text -> whole text");
        check([[Switch bottomLines:@"" count:3] isEqualToString:@""], @"bottomLines: empty -> empty");
        check([Switch occurrencesOf:@"/effort high" inText:@"❯ /effort high\n…\n❯ /effort high\n"] == 2,
              @"occurrencesOf: counts both occurrences");
        check([Switch occurrencesOf:@"aa" inText:@"aaaa"] == 2, @"occurrencesOf: non-overlapping");
        check([Switch occurrencesOf:@"x" inText:@""] == 0 && [Switch occurrencesOf:@"" inText:@"abc"] == 0,
              @"occurrencesOf: empty needle or text -> 0");

        printf("\n== WATCH/VERIFY decision (the confirm-dialog path that broke live) ==\n");
        // A Claude model step expecting "Opus 4.8", auto-confirm on.
        PlanStep *ms = [PlanStep new]; ms.kind = StepWaitState; ms.expectModel = @"Opus 4.8";
        ms.handlesDialog = YES; ms.text = @"Set model to";
        // frame 1: dialog open -> should CONFIRM
        PaneState *f1 = [PaneState new]; [AXState classifyText:claudeDialog() into:f1];
        check([Switch decideStep:ms pane:f1 autoAnswer:YES policy:DialogConfirm confirmed:NO] == StepDecConfirm,
              @"dialog open + confirm policy -> press confirm");
        // frame 1 under ask policy -> DIALOG_OPEN
        check([Switch decideStep:ms pane:f1 autoAnswer:NO policy:DialogAsk confirmed:NO] == StepDecDialogOpen,
              @"dialog open + ask policy -> DIALOG_OPEN");
        // frame 1 under cancel policy -> cancel
        check([Switch decideStep:ms pane:f1 autoAnswer:YES policy:DialogCancel confirmed:NO] == StepDecCancel,
              @"dialog open + cancel policy -> press cancel");
        f1.paneText = claudeDialog();
        // frame 2: after confirming, status line now shows Opus 4.8, no dialog -> MATCHED
        NSString *t2 = @"⏺ done\n❯ \n──────\n  📂 proj  ·  Opus 4.8  ▰▰▰\n";
        PaneState *f2 = [PaneState new]; f2.paneText = t2; [AXState classifyText:t2 into:f2];
        check([Switch decideStep:ms pane:f2 autoAnswer:YES policy:DialogConfirm confirmed:YES] == StepDecMatched,
              @"post-confirm status line Opus 4.8 -> MATCHED");
        // NOT matched while the dialog (which names Opus 4.8 in its body) is still open
        check([Switch decideStep:ms pane:f1 autoAnswer:YES policy:DialogConfirm confirmed:YES] != StepDecMatched,
              @"dialog body naming Opus 4.8 does NOT count as matched");
        // model 'not found' error
        NSString *te = @"❯ /model xyz\n  ⎿  Model 'xyz' not found\n  📂 proj  ·  Fable 5\n";
        PaneState *fe = [PaneState new]; fe.paneText = te; [AXState classifyText:te into:fe];
        check([Switch decideStep:ms pane:fe autoAnswer:YES policy:DialogConfirm confirmed:NO] == StepDecError,
              @"'not found' -> error");
        // effort step verified via printed line when the chip is absent
        PlanStep *es = [PlanStep new]; es.kind = StepWaitState; es.expectEffort = @"max"; es.text = @"Set effort level to";
        NSString *tef = @"❯ /effort max\n  ⎿  Set effort level to max (this session only): …\n  📂 proj  ·  Fable 5\n";
        PaneState *fef = [PaneState new]; fef.paneText = tef; [AXState classifyText:tef into:fef];
        check([Switch decideStep:es pane:fef autoAnswer:NO policy:DialogAsk confirmed:NO] == StepDecMatched,
              @"effort verified via printed line when chip absent");
        // effort step facing the "Change effort level?" dialog (live 2026-07-13)
        PlanStep *ed = [PlanStep new]; ed.kind = StepWaitState; ed.expectEffort = @"high";
        ed.handlesDialog = YES; ed.text = @"Set effort level to";
        NSString *tdlg = @"  Change effort level?\n  Your next response will be slower and use more tokens\n"
                         @"❯ 1. Yes, switch to high\n  2. No, go back\n";
        PaneState *fdlg = [PaneState new]; fdlg.paneText = tdlg; [AXState classifyText:tdlg into:fdlg];
        check([Switch decideStep:ed pane:fdlg autoAnswer:YES policy:DialogConfirm confirmed:NO] == StepDecConfirm,
              @"effort dialog + confirm policy -> press confirm");
        check([Switch decideStep:ed pane:fdlg autoAnswer:NO policy:DialogAsk confirmed:NO] == StepDecDialogOpen,
              @"effort dialog + ask policy -> DIALOG_OPEN");
        check([Switch decideStep:ed pane:fdlg autoAnswer:YES policy:DialogCancel confirmed:NO] == StepDecCancel,
              @"effort dialog + cancel policy -> press cancel");

        // Scrollback safety (Codex #2): needles above the bottom window are history,
        // not verdicts. An old error must not fail a live wait; an old success line
        // must not satisfy one.
        NSMutableString *filler = [NSMutableString string];
        for (int i = 0; i < 20; i++) [filler appendFormat:@"⏺ output line %d\n", i];
        NSString *staleErr = [NSString stringWithFormat:
            @"❯ /model xyz\n  ⎿  Model 'xyz' not found\n%@❯ \n──────\n  📂 proj  ·  Fable 5\n", filler];
        PaneState *fse = [PaneState new]; fse.paneText = staleErr; [AXState classifyText:staleErr into:fse];
        check([Switch decideStep:ms pane:fse autoAnswer:YES policy:DialogConfirm confirmed:NO] != StepDecError,
              @"'not found' buried in scrollback does NOT fail a live wait");
        PlanStep *ps = [PlanStep new]; ps.kind = StepWaitState; ps.text = @"Switched to gpt-5.5";
        NSString *staleOk = [NSString stringWithFormat:
            @"• Switched to gpt-5.5\n%@› type here\n  gpt-5.6-sol low · /Users/x\n", filler];
        PaneState *fso = [PaneState new]; fso.paneText = staleOk; [AXState classifyText:staleOk into:fso];
        check([Switch decideStep:ps pane:fso autoAnswer:NO policy:DialogAsk confirmed:NO] == StepDecWait,
              @"success needle buried in scrollback does NOT satisfy a live wait");
        check([Switch decideStep:ps pane:fdlg autoAnswer:NO policy:DialogAsk confirmed:NO] != StepDecMatched,
              @"needle absent -> no match (sanity)");

        // Decorated dialog target (live 2026-07-13 14:35): Claude names the target
        // "Opus 4.8 (1M context) (default)" — the qualifiers must not make our own
        // dialog read as foreign (exact-equality did, and auto-confirm broke).
        check([Switch dialogTarget:@"Opus 4.8 (1M context) (default)" matchesExpected:@"Opus 4.8"],
              @"decorated model target still matches expected 'Opus 4.8'");
        check([Switch dialogTarget:@"high" matchesExpected:@"high"], @"plain effort target matches");
        check([Switch dialogTarget:@"opus 4.8 (1M context)" matchesExpected:@"Opus 4.8"],
              @"decorated match is case-insensitive");
        check(![Switch dialogTarget:@"Opus 4.8.1" matchesExpected:@"Opus 4.8"],
              @"'Opus 4.8.1' is NOT 'Opus 4.8' (boundary required)");
        check(![Switch dialogTarget:@"higher" matchesExpected:@"high"],
              @"'higher' is NOT 'high' (boundary required)");
        check(![Switch dialogTarget:@"Sonnet 5" matchesExpected:@"Opus 4.8"], @"different model -> no match");
        check(![Switch dialogTarget:@"" matchesExpected:@"Opus 4.8"]
              && ![Switch dialogTarget:@"Opus 4.8" matchesExpected:@""],
              @"empty target or expectation -> no match");
        NSString *decDlg =
          @"   Switch model?\n"
          @"   This conversation is cached for the current model. Switching to Opus 4.8 (1M context) (default) means…\n"
          @"   ❯ 1. Yes, switch to Opus 4.8 (1M context) (default)\n"
          @"     2. No, go back\n";
        PaneState *fdec = [PaneState new]; fdec.paneText = decDlg; [AXState classifyText:decDlg into:fdec];
        check([Switch decideStep:ms pane:fdec autoAnswer:YES policy:DialogConfirm confirmed:NO] == StepDecConfirm,
              @"decorated dialog + confirm policy -> press confirm (the live failure)");

        // Foreign dialog (Codex #5): a dialog whose target is NOT this step's expectation
        // must never be keyed, even under confirm/cancel policy — return DIALOG_OPEN.
        PlanStep *other = [PlanStep new]; other.kind = StepWaitState; other.expectModel = @"Sonnet 5";
        other.handlesDialog = YES; other.text = @"Set model to";
        check([Switch decideStep:other pane:f1 autoAnswer:YES policy:DialogConfirm confirmed:NO] == StepDecDialogOpen,
              @"dialog targeting Opus 4.8 while expecting Sonnet 5 -> DIALOG_OPEN (never keyed)");
        check([Switch decideStep:other pane:f1 autoAnswer:YES policy:DialogCancel confirmed:NO] == StepDecDialogOpen,
              @"foreign dialog under cancel policy -> DIALOG_OPEN (not even cancel)");

        printf("\n== ALREADY_SET no-op ==\n");
        PaneState *cur = [PaneState new];
        [AXState classifyText:@"❯ \n  📂 proj  ·  Fable 5  ▰▰▰\n                 ◉ high · /effort\n" into:cur];
        check([Switch pane:cur alreadyAtModel:@"Fable 5" effort:@"high"], @"already Fable 5 + high -> ALREADY_SET");
        check(![Switch pane:cur alreadyAtModel:@"Opus 4.8" effort:@"high"], @"different model -> not already set");
        check(![Switch pane:cur alreadyAtModel:@"Fable 5" effort:@"max"], @"different effort -> not already set");
        check([Switch pane:cur alreadyAtModel:@"Fable 5" effort:nil], @"model-only gear, model matches -> ALREADY_SET");
        PaneState *noEff = [PaneState new];
        [AXState classifyText:@"❯ \n  📂 proj  ·  Fable 5  ▰▰▰\n" into:noEff];  // no effort chip
        check(![Switch pane:noEff alreadyAtModel:@"Fable 5" effort:@"high"], @"effort unknown + effort gear -> not already set (re-applies)");
        check([Switch pane:noEff alreadyAtModel:@"Fable 5" effort:nil], @"effort unknown + model-only gear -> ALREADY_SET");

        printf("\n== claude cwd match tiers (live ambiguity: Parent Project) ==\n");
        // Two sessions, one in 'Parent Project' and one nested in its
        // 'Sub Project' subdir, must NOT be an ambiguous tie: exact basename is tier 1,
        // the nested session only tier 2, so attribution can pick the focused pane.
        check([Attribution claudeCwdMatchTier:@"/u/me/Parent Project"
                                         hint:@"Parent Project"] == 1,
              @"exact basename -> tier 1");
        check([Attribution claudeCwdMatchTier:@"/u/me/Parent Project/Sub Project"
                                         hint:@"Parent Project"] == 2,
              @"session nested below hint dir -> tier 2 (weaker than exact)");
        check([Attribution claudeCwdMatchTier:@"/Users" hint:@"Shared"] == 3,
              @"hint is an existing child dir of cwd -> tier 3 (weakest)");
        check([Attribution claudeCwdMatchTier:@"/u/me/Duplicate HQ"
                                         hint:@"Parent Project"] == 0,
              @"unrelated cwd -> 0 (no match)");
        check([Attribution claudeCwdMatchTier:@"" hint:@"x"] == 0
              && [Attribution claudeCwdMatchTier:@"/u" hint:@""] == 0,
              @"empty cwd or hint -> 0");

        printf("\n== codex fg-group native detection (real 8-proc capture) ==\n");
        // Exact structure captured live on codex tty 0x18 (fg leader = node pid 64491,
        // pgid 64491). Native codex 64494 shares that pgid; sub-agents are in other groups.
        ProcRow *(^mk)(pid_t,pid_t,NSString*) = ^ProcRow*(pid_t pid,pid_t pgid,NSString*comm){
            ProcRow *r=[ProcRow new]; r.pid=pid; r.pgid=pgid; r.comm=comm; return r; };
        NSArray *codexRows = @[
            mk(97960,64540,@"codex"),            // sub-agent codex (other group)
            mk(97959,64540,@"node"),
            mk(69809,69809,@"codex-code-mode-"), // NOT exactly "codex"
            mk(64541,64541,@"node"),
            mk(64540,64540,@"node_repl"),
            mk(64494,64491,@"codex"),            // <- the real native, same fg group
            mk(64491,64491,@"node"),             // fg leader
            mk(64291,64291,@"zsh"),
        ];
        ProcRow *nat = [Attribution nativeCodexInGroup:64491 rows:codexRows];
        check(nat != nil && nat.pid == 64494, @"native codex bound to fg-group pid 64494");
        check([Attribution nativeCodexInGroup:64540 rows:codexRows].pid == 97960, @"a different fg group binds its own codex");
        check([Attribution nativeCodexInGroup:99999 rows:codexRows] == nil, @"no codex in an unknown group -> nil");
        // a claude-only tree has no native codex
        NSArray *claudeRows = @[ mk(58781,58781,@"claude.exe"), mk(57133,57133,@"zsh") ];
        check([Attribution nativeCodexInGroup:58781 rows:claudeRows] == nil, @"claude session -> no codex native");

        printf("\n== injection keycode coverage (current keyboard layout) ==\n");
        // Every char the protocols can type must resolve to a REAL keycode: Warp
        // ignores the unicode payload of synthetic events, so an unresolvable char
        // would fall back to the transport Warp drops.
        {
            NSString *charset = @"/model fable sonnet haiku default /effort low medium high xhigh max ultracode auto [1m] gpt-5.6-sol 0123456789.-";
            BOOL all = YES; unichar bad = 0;
            for (NSUInteger i = 0; i < charset.length; i++) {
                unichar c = [charset characterAtIndex:i];
                if (![Inject resolvesChar:c]) { all = NO; bad = c; break; }
            }
            check(all, all ? @"every protocol char resolves to a keycode"
                           : [NSString stringWithFormat:@"char '%C' does not resolve to a keycode", bad]);
        }
        // canTypeText is the fail-closed gate typeText enforces: a string with any
        // unmappable char must be refused whole (no partial typing, no keycode-0).
        check([Inject canTypeText:@"/model fable"], @"canTypeText: plain protocol text -> YES");
        check([Inject canTypeText:@"/effort xhigh"], @"canTypeText: effort command -> YES");
        check(![Inject canTypeText:@"/model 日本語"], @"canTypeText: unmappable chars -> NO (refuse whole string)");
        check(![Inject canTypeText:@"ok bad"], @"canTypeText: line separator -> NO");

        printf("\n== config: gear remaps ==\n");
        {
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"ss-gear-%d.toml", getpid()]];
            setenv("STICKSHIFT_CONFIG", tmp.fileSystemRepresentation, 1);
            [@"gear.4.claude = \"sonnet max\"\n"          // model + effort
             @"gear.ultra.codex = \"gpt-5.5\"\n"          // model only, lowercase gear name
             @"gear.4.codex = \"bad;model high\"\n"       // unsafe model -> ignored
             @"gear.9.claude = \"fable\"\n"               // unknown gear -> ignored
              writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@(0600)} ofItemAtPath:tmp error:nil];
            Config *gc = [Config load];
            GearTuple *g4c = [gc tupleForGear:@"4" kind:AgentClaude];
            check([g4c.model isEqualToString:@"sonnet"] && [g4c.effort isEqualToString:@"max"],
                  @"gear.4.claude remapped to sonnet/max");
            GearTuple *guc = [gc tupleForGear:@"ULTRA" kind:AgentCodex];
            check([guc.model isEqualToString:@"gpt-5.5"] && guc.effort == nil,
                  @"gear.ultra.codex remapped, model-only, case-insensitive gear");
            GearTuple *g4x = [gc tupleForGear:@"4" kind:AgentCodex];
            check([g4x.model isEqualToString:@"gpt-5.6-sol"],
                  @"unsafe remap value ignored (default kept)");
            check([gc tupleForGear:@"1" kind:AgentClaude] != nil, @"untouched gears keep defaults");
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            unsetenv("STICKSHIFT_CONFIG");
        }

        printf("\n== config: enabled_terminals is honored ==\n");
        {
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"ss-term-%d.toml", getpid()]];
            setenv("STICKSHIFT_CONFIG", tmp.fileSystemRepresentation, 1);
            [@"enabled_terminals = [\"dev.warp.Warp-Stable\", \"com.googlecode.iterm2\"]\n"
                writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@(0600)} ofItemAtPath:tmp error:nil];
            Config *tc = [Config load];
            check(tc.enabledTerminals.count == 2 &&
                  [tc.enabledTerminals containsObject:@"com.googlecode.iterm2"],
                  @"enabled_terminals from config.toml is parsed and applied");
            // invalid entries (shell metachars, no dot) are skipped; empty list keeps default
            [@"enabled_terminals = [\"bad;id\", \"nodots\", \"com.apple.Terminal\"]\n"
                writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil];
            Config *tc2 = [Config load];
            check(tc2.enabledTerminals.count == 1 &&
                  [tc2.enabledTerminals containsObject:@"com.apple.Terminal"],
                  @"invalid bundle-id entries are skipped");
            [@"enabled_terminals = []\n" writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:nil];
            Config *tc3 = [Config load];
            check([tc3.enabledTerminals containsObject:@"dev.warp.Warp-Stable"],
                  @"empty list keeps the compiled-in default (fail closed)");
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            unsetenv("STICKSHIFT_CONFIG");
        }

        printf("\n== manifest: version lookup across npm layouts ==\n");
        {
            // codex layout: package.json THREE levels above the binary
            // (@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex) —
            // the one-level lookup returned nil and refused a qualified codex (live).
            NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"ss-manifest-%d", getpid()]];
            NSString *deep = [root stringByAppendingPathComponent:@"vendor/aarch64-apple-darwin/bin"];
            [[NSFileManager defaultManager] createDirectoryAtPath:deep withIntermediateDirectories:YES attributes:nil error:nil];
            [@"{\"version\":\"9.9.9-darwin-arm64\"}" writeToFile:[root stringByAppendingPathComponent:@"package.json"]
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSString *fakeBin = [deep stringByAppendingPathComponent:@"codex"];
            [@"x" writeToFile:fakeBin atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSString *v = [[Manifest shared] versionFromImage:fakeBin kind:AgentCodex];
            check([v isEqualToString:@"9.9.9"], @"version found 3 levels up, -darwin suffix stripped");
            // claude layout: package.json one level above bin/
            NSString *cbin = [root stringByAppendingPathComponent:@"bin/claude.exe"];
            [[NSFileManager defaultManager] createDirectoryAtPath:[root stringByAppendingPathComponent:@"bin"]
                withIntermediateDirectories:YES attributes:nil error:nil];
            [@"x" writeToFile:cbin atomically:YES encoding:NSUTF8StringEncoding error:nil];
            check([[[Manifest shared] versionFromImage:cbin kind:AgentClaude] isEqualToString:@"9.9.9"],
                  @"version found 1 level up (claude layout)");
            [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
        }

        printf("\n== manifest: version drift policy ==\n");
        // Version is a drift signal, not an identity gate (live 2026-07-13: the exact
        // pin refused codex 0.144.3 minutes after a routine update). Identity
        // (signature/team/id) stays hard; series and drift are tolerated.
        check([Manifest matchForVersion:@"0.144.1" kind:AgentCodex] == VersionExact,
              @"qualified version -> exact");
        check([Manifest matchForVersion:@"0.144.3" kind:AgentCodex] == VersionSameSeries,
              @"patch bump (0.144.3) -> same series (the live false refusal)");
        check([Manifest matchForVersion:@"0.145.0" kind:AgentCodex] == VersionDrift,
              @"out-of-series -> drift (allowed, logged)");
        check([Manifest matchForVersion:@"2.1.209" kind:AgentClaude] == VersionSameSeries,
              @"claude patch bump -> same series");
        check([Manifest matchForVersion:nil kind:AgentCodex] == VersionUnknown
              && [Manifest matchForVersion:@"" kind:AgentClaude] == VersionUnknown,
              @"unresolvable version -> unknown (hard refusal)");

        printf("\n== injection safety ==\n");
        check([Config isInjectionSafe:@"fable"], @"safe: fable");
        check([Config isInjectionSafe:@"sonnet[1m]"], @"safe: sonnet[1m]");
        check(![Config isInjectionSafe:@"foo; rm -rf"], @"unsafe: shell metachars");
        check(![Config isInjectionSafe:@"has space"], @"unsafe: whitespace");
        check(![Config isInjectionSafe:@"/model x"], @"unsafe: slash+space");

        printf("\n== robustness: adversarial pane content must not crash ==\n");
        NSArray *evil = @[ @"", @"\n\n\n", @"📂", @"📂 ", @"· · ·", @"❯", @"❯ 1.",
            @"Switch model?", @"1. Yes, switch to", @"› 99999999999999999999. huge",
            @"› -3. neg", @"›  . nolabel", @"📂\t·\tFable 5\t", @"❯ /model $(rm -rf ~)\n📂 x · Fable 5",
            [@"" stringByPaddingToLength:100000 withString:@"📂 x · Fable 5\n❯ \n" startingAtIndex:0],
            [@"" stringByPaddingToLength:50000 withString:@"a" startingAtIndex:0] ];
        BOOL noCrash = YES; NSInteger badRow = 0;
        for (NSString *e in evil) {
            @try {
                PaneState *p = [PaneState new]; p.paneText = e; [AXState classifyText:e into:p];
                if ([AXState codexPickerRowFor:@"x" inText:e] < 0) badRow++;
                [Config isInjectionSafe:e];
            } @catch (NSException *ex) { noCrash = NO; }
        }
        check(noCrash, @"classifier/parsers survive adversarial input without crashing");
        check(badRow == 0, @"picker row is never negative");

        printf("\n%s (%d failures)\n", failures==0?"ALL PASS":"FAILURES", failures);
        return failures == 0 ? 0 : 1;
    }
}
