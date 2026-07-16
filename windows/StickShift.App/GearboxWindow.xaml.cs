using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using Microsoft.Web.WebView2.Core;
using StickShift.Core;
using StickShift.Os;

namespace StickShift.App;

// Hosts Mark Kashef's gearbox.html (unmodified) in WebView2 and bridges a gear-pull to the proven
// Windows engine (SwitchDriver.Shift). A ~10-line shim maps the gear's webkit.messageHandlers.*
// calls onto WebView2's chrome.webview.postMessage, so the HTML transfers with zero edits — the
// same technique validated in the stickshift-windows POC, re-pointed from that POC's GearEngine to
// the faithful port's SwitchDriver (read -> precheck -> inject -> verify, fail-closed).
public partial class GearboxWindow : Window
{
    string? _explicitTarget;
    readonly Config _cfg = new();

    // Win32 caption-drag: DragMove() can't move this window because the WebView2 child HWND owns the
    // mouse capture, so WPF's own input system never sees the button-down. Asking the window manager
    // directly (ReleaseCapture + WM_NCLBUTTONDOWN/HTCAPTION) starts a native move-loop that works
    // regardless of which child HWND has focus — the standard frameless-drag fix for hosted browsers.
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    const int WM_NCLBUTTONDOWN = 0xA1;
    const int HTCAPTION = 0x2;

    // The gear speaks WKWebView; give it that surface over WebView2 (the four bridge messages
    // Mark's WINDOWS.md names: shift / policy / resize / drag).
    const string Shim = @"
        window.webkit = { messageHandlers: {
          shift:  { postMessage: function(m){ window.chrome.webview.postMessage({name:'shift', body:m}); } },
          policy: { postMessage: function(m){ window.chrome.webview.postMessage({name:'policy',body:m}); } },
          resize: { postMessage: function(m){ window.chrome.webview.postMessage({name:'resize',body:m}); } },
          drag:   { postMessage: function(m){ window.chrome.webview.postMessage({name:'drag',  body:m}); } }
        }};";

    // Host-shell augmentation (NOT a gearbox.html edit — injected at document-create, like the shim):
    // an always-on-top toggle. 'Un-pin' only means something for a real OS window, so it belongs to
    // the Windows shell, not Mark's cross-platform HTML. Adds a pin button beside his compact control.
    const string PinButton = @"
        (function(){
          function add(){
            var a=document.getElementById('btnCompact');
            if(!a){ setTimeout(add,50); return; }
            if(document.getElementById('btnPin')) return;
            var b=document.createElement('button');
            b.id='btnPin'; b.textContent='📌'; b.className=a.className;
            b.title='Pinned on top — click to un-pin';
            var pinned=true;
            b.addEventListener('click',function(){
              pinned=!pinned;
              b.style.opacity = pinned ? '1' : '0.4';
              b.title = pinned ? 'Pinned on top — click to un-pin' : 'Un-pinned — click to pin on top';
              window.chrome.webview.postMessage({name:'pin',body:{pinned:pinned}});
            });
            a.parentNode.insertBefore(b,a);
          }
          if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',add); else add();
        })();";

    public GearboxWindow(string? target)
    {
        _explicitTarget = target;
        // In the gearbox, PULLING A GEAR *is* the confirmation (macOS app default, AppDelegate.m:47-51):
        // auto-confirm the "Switch model?" dialog so a pull completes instead of stalling at DIALOG_OPEN
        // mid-conversation. The CLI keeps the conservative Ask default; this app-level choice matches Mark's.
        _cfg.DialogPolicy = DialogPolicy.Confirm;
        _cfg.AutoAnswerEnabled = true;
        InitializeComponent();
        Loaded += OnLoaded;
        KeyDown += (_, keyEvent) => { if (keyEvent.Key == Key.Escape) Close(); };
    }

    async void OnLoaded(object sender, RoutedEventArgs e)
    {
        await web.EnsureCoreWebView2Async();
        var core = web.CoreWebView2;
        await core.AddScriptToExecuteOnDocumentCreatedAsync(Shim);
        await core.AddScriptToExecuteOnDocumentCreatedAsync(PinButton);
        core.WebMessageReceived += OnWebMessage;
        core.NavigationCompleted += async (_, _) => await PushProfiles();

        var html = Path.Combine(AppContext.BaseDirectory, "gearbox.html");
        core.Navigate(new Uri(html).AbsoluteUri);
    }

    async System.Threading.Tasks.Task PushProfiles()
    {
        // Gears from the Config gear table (spike-7 order). The gate value is the gear passed to
        // SwitchDriver; the GUI exposes the H-pattern 1..4 (5 / R / ULTRA remain CLI-reachable).
        // Efforts are {token,label} objects — Mark's renderEfforts() reads e.label; bare strings
        // rendered as "UNDEFINED" on every throttle tick.
        const string profiles =
            "window.setProfiles({claude:{name:'Claude Code'," +
            "models:[{gate:'1',token:'haiku',label:'Haiku 4.5'},{gate:'2',token:'sonnet',label:'Sonnet 5'}," +
            "{gate:'3',token:'default',label:'Opus 4.8'},{gate:'4',token:'fable',label:'Fable 5'}]," +
            "efforts:[{token:'low',label:'low'},{token:'medium',label:'medium'},{token:'high',label:'high'}," +
            "{token:'xhigh',label:'xhigh'},{token:'max',label:'max'},{token:'ultracode',label:'ultracode'}]," +
            "modelEfforts:{}}," +
            "codex:{name:'Codex',models:[],efforts:[],modelEfforts:{}}})";
        await web.CoreWebView2.ExecuteScriptAsync(profiles);
        PushLive();
    }

    // Feed the console/readout the session's ACTUAL model + effort so "acting on … · model · effort"
    // shows real state instead of the empty push that left it blank. Read off the UI thread (UIA is
    // slow), then marshal the setLive() call back. Fire-and-forget; failure just leaves it blank.
    //
    // expectModel: after a verified shift, the footer redraws a beat AFTER the confirmation line the
    // verify keys on — an instant re-read catches the DYING footer (old model) and yanks the knob
    // back to the previous gate (observed live: shift to Fable held, UI snapped back to Opus). So
    // when the caller knows what the shift just verified, poll until the footer agrees (or ~3s).
    void PushLive(string? expectModel = null)
    {
        System.Threading.Tasks.Task.Run(() =>
        {
            // Empty agent (not "claude") when nothing qualifies, so the HTML shows "focus a terminal
            // pane" with the live chip off — matching the macOS shell, instead of a fake green chip.
            string agentKind = "", modelDisplay = "", modelToken = "", effortText = "";
            try
            {
                string targetTitle = ResolveTarget();
                if (!string.IsNullOrEmpty(targetTitle))
                {
                    var targetWindow = WindowFocus.FindWindowByTitle(targetTitle);
                    if (targetWindow != IntPtr.Zero)
                    {
                        var paneState = WindowFocus.ReadActiveAgentPane(targetWindow);
                        var readDeadline = DateTime.UtcNow.AddSeconds(3);
                        while (expectModel != null
                               && !Switch.DialogTargetMatchesExpected(paneState.ModelText, expectModel)
                               && DateTime.UtcNow < readDeadline)
                        {
                            Thread.Sleep(200);
                            paneState = WindowFocus.ReadActiveAgentPane(targetWindow);
                        }
                        agentKind = paneState.Agent switch
                        {
                            AgentKind.Claude => "claude",
                            AgentKind.Codex => "codex",
                            _ => ""
                        };
                        if (paneState.Agent != AgentKind.Unknown)
                        {
                            modelDisplay = paneState.ModelText ?? "";
                            effortText = paneState.EffortText ?? "";
                            modelToken = TokenForModel(modelDisplay);
                        }
                    }
                }
            }
            catch { }
            Dispatcher.Invoke(async () =>
            {
                string setLiveScript =
                    $"window.setLive({{agent:{ToJsLiteral(agentKind)},model:{ToJsLiteral(modelDisplay)}," +
                    $"token:{ToJsLiteral(modelToken)},effort:{ToJsLiteral(effortText)}}})";
                await web.CoreWebView2.ExecuteScriptAsync(setLiveScript);
            });
        });
    }

    static string TokenForModel(string m)
    {
        if (m.Contains("Haiku")) return "haiku";
        if (m.Contains("Sonnet")) return "sonnet";
        if (m.Contains("Opus")) return "default";
        if (m.Contains("Fable")) return "fable";
        return "";
    }

    // The target Claude/Codex session: an explicit --target substring, else the first agent session
    // the reader can find (auto-detect). Resolved fresh at shift time.
    string ResolveTarget()
    {
        if (!string.IsNullOrWhiteSpace(_explicitTarget)) return _explicitTarget!;
        foreach (var pane in UiaPaneReader.ReadTerminalPanes())
        {
            var st = new PaneState();
            PaneClassifier.ClassifyText(pane.BufferText, st);
            if (st.Agent != AgentKind.Unknown) return pane.WindowTitle;
        }
        return "";
    }

    void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            using var message = JsonDocument.Parse(e.WebMessageAsJson);
            var messageName = message.RootElement.GetProperty("name").GetString();

            if (messageName == "drag")
            {
                var windowHandle = new WindowInteropHelper(this).EnsureHandle();
                ReleaseCapture();
                SendMessage(windowHandle, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
                return;
            }
            if (messageName == "pin")
            {
                bool pinned = message.RootElement.TryGetProperty("body", out var pinBody)
                              && pinBody.TryGetProperty("pinned", out var pinnedValue) && pinnedValue.GetBoolean();
                Topmost = pinned;
                return;
            }
            if (messageName == "resize")
            {
                // Mark's collapse (–) hides the stage and asks the host to shrink to the header bar;
                // honor it so the button doesn't leave dead space below a full-height frame. Expanded
                // height mirrors the macOS shell's 760x440 content rect (AppDelegate.m).
                bool collapsed = message.RootElement.TryGetProperty("body", out var resizeBody)
                               && resizeBody.TryGetProperty("compact", out var compactValue) && compactValue.GetBoolean();
                Height = collapsed ? 64 : 440;
                return;
            }
            if (messageName == "policy")
            {
                var policyName = message.RootElement.GetProperty("body").TryGetProperty("policy", out var policyValue) ? policyValue.GetString() : null;
                _cfg.DialogPolicy = policyName switch { "ask" => DialogPolicy.Ask, "cancel" => DialogPolicy.Cancel, _ => DialogPolicy.Confirm };
                _cfg.AutoAnswerEnabled = policyName is "confirm" or "cancel";
                return;
            }
            if (messageName != "shift") return;

            var body = message.RootElement.GetProperty("body");
            string gate = body.TryGetProperty("gate", out var gateProperty) ? gateProperty.GetString() ?? "" : "";
            // The UI's tuple IS the shift (Mark's runModelToken:effort: semantics): fire() sends
            // {model, effort, gate} on every action — gear pulls AND throttle-only moves (where
            // model = the live token and gate may be ''). gate is only echoed back for the glow.
            string uiModelToken = body.TryGetProperty("model", out var modelProperty) ? modelProperty.GetString() ?? "" : "";
            string uiEffortToken = body.TryGetProperty("effort", out var effortProperty) ? effortProperty.GetString() ?? "" : "";
            GearTuple? uiTuple = uiModelToken.Length > 0
                ? new GearTuple(uiModelToken, uiEffortToken.Length > 0 ? uiEffortToken : null)
                : null;   // no model token (shouldn't happen — fire() guards) -> fall back to the gear table

            System.Threading.Tasks.Task.Run(() =>
            {
                ShiftOutcome outcome;
                try
                {
                    string targetTitle = ResolveTarget();
                    outcome = string.IsNullOrEmpty(targetTitle)
                        ? new ShiftOutcome { Reason = "NOT_TERMINAL", Detail = "no Claude/Codex session found" }
                        : SwitchDriver.Shift(targetTitle, gate, _cfg, commit: true, log: null, tupleOverride: uiTuple);
                }
                catch (Exception readException)
                {
                    // A UIA fault must STILL resolve the HTML's pending state, or the gearbox freezes
                    // on a phantom gear (one-outcome-per-shift contract). Deliver an error outcome.
                    outcome = new ShiftOutcome { Reason = "READ_ERROR", Stage = "INJECT", Detail = readException.Message };
                }

                // Buckets mirror the macOS shell (AppDelegate.m): landed = changed/already; warnable =
                // every refusal PLUS UNKNOWN_FINAL_STATE (committed but unverified) — so a shift that
                // likely took doesn't render as a red error and snap the knob back to the old model.
                bool landed = outcome.Reason is "CHANGED" or "ALREADY_SET";
                bool warnable = outcome.Reason is "BUSY" or "DRAFT_PRESENT" or "DIALOG_OPEN" or "NOT_TERMINAL"
                    or "NO_AGENT" or "NO_FOCUS" or "LOCKED" or "UNCHANGED" or "UNKNOWN_FINAL_STATE";
                Dispatcher.Invoke(async () =>
                {
                    string outcomeScript =
                        $"window.outcome({{reason:{ToJsLiteral(outcome.Reason)},detail:{ToJsLiteral(outcome.Detail)}," +
                        $"ok:{(landed ? "true" : "false")},warn:{(warnable ? "true" : "false")}," +
                        $"activeGate:{ToJsLiteral(landed ? gate : "")}}})";
                    await web.CoreWebView2.ExecuteScriptAsync(outcomeScript);
                });
                // Reconcile the console/knob with the session's REAL post-shift state on ANY commit
                // (landed, or UNKNOWN_FINAL_STATE which likely landed) — never leave the UI on the old model.
                if (landed || outcome.Committed)
                {
                    string? modelToken = uiTuple?.Model ?? _cfg.TupleForGear(gate, AgentKind.Claude)?.Model;
                    PushLive(landed && modelToken != null ? ShiftProtocol.ClaudeDisplayForToken(modelToken) : null);
                }
            });
        }
        catch { }
    }

    // Outbound JS-literal encoder: JSON-serialize so every value reaching ExecuteScriptAsync is a
    // properly-escaped double-quoted literal — closes newline / U+2028 / U+2029 / quote breakouts
    // that a hand-rolled '..'-escaper misses when pane-derived text (model, detail) is untrusted.
    static string ToJsLiteral(string? value) => System.Text.Json.JsonSerializer.Serialize(value ?? "");
}
