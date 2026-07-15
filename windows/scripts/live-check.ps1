#requires -Version 5.1
<#
.SYNOPSIS
  One-shot live acceptance check for the StickShift Windows port.

.DESCRIPTION
  This is the ONE test CI cannot run: it drives a REAL, authenticated Claude Code (or Codex)
  session in Windows Terminal end to end. Run it on a Windows box with the agent installed and
  logged in. It builds the CLI, lists what StickShift sees, dry-runs a shift, then (on your
  confirmation, against a THROWAWAY session) commits a real shift and proves it landed two ways:
  the pane's own status line changed AND %USERPROFILE%\.claude\settings.json was rewritten.

.PARAMETER Target
  A substring of the Windows Terminal window title running the agent. Give the session a
  distinctive title first (inside Claude Code: /rename my-throwaway-session).

.PARAMETER Gear
  Which gear to shift into (1 2 3 4 5 R ULTRA). Pick one DIFFERENT from the current model so the
  change is observable. Default: 2.

.EXAMPLE
  pwsh -File windows\scripts\live-check.ps1 -Target "my-throwaway-session" -Gear 3
#>
param(
  [Parameter(Mandatory = $true)] [string] $Target,
  [string] $Gear = "2"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)   # windows/
$cliProj = Join-Path $root "StickShift.Cli/StickShift.Cli.csproj"
$settings = Join-Path $env:USERPROFILE ".claude/settings.json"

function Step($n, $msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }

Step 1 "Build the CLI (Release)"
dotnet build $cliProj -c Release | Out-Null
$exe = Join-Path $root "StickShift.Cli/bin/Release/net10.0-windows/stickshift.exe"
if (-not (Test-Path $exe)) { throw "build did not produce $exe" }
Write-Host "  ok: $exe"

Step 2 "What StickShift sees right now (--list)"
& $exe --list

Step 3 "Read the target pane's current state (--dump)"
& $exe --dump --target $Target

Step 4 "DRY RUN — the plan, no keystrokes typed"
& $exe $Gear --target $Target
if ($LASTEXITCODE -ne 0) { Write-Warning "dry run refused (exit $LASTEXITCODE). Fix the refusal above before committing."; }

Step 5 "COMMIT — this types into the target session"
Write-Host "  Target : *$Target*   Gear: $Gear" -ForegroundColor Yellow
Write-Host "  Make sure that window is a THROWAWAY agent session (a mis-key costs nothing there)." -ForegroundColor Yellow
$ans = Read-Host "  Type EXACTLY 'yes' to commit the shift"
if ($ans -ne "yes") { Write-Host "  aborted (no commit)."; return }

$before = if (Test-Path $settings) { (Get-Item $settings).LastWriteTimeUtc } else { [DateTime]::MinValue }
& $exe $Gear --target $Target --commit
$commitExit = $LASTEXITCODE
Start-Sleep -Milliseconds 800
$after = if (Test-Path $settings) { (Get-Item $settings).LastWriteTimeUtc } else { [DateTime]::MinValue }

Step 6 "Verify"
& $exe --dump --target $Target
$mtimeMoved = $after -gt $before
Write-Host ""
Write-Host ("  CLI outcome exit code : {0}" -f $commitExit)
Write-Host ("  settings.json mtime   : {0} (before={1:o} after={2:o})" -f ($(if ($mtimeMoved) {"MOVED"} else {"unchanged"}), $before, $after))
if ($commitExit -eq 0 -and $mtimeMoved) {
  Write-Host "`nLIVE CHECK: PASS — the real session shifted and settings.json was rewritten." -ForegroundColor Green
  exit 0
} else {
  Write-Host "`nLIVE CHECK: NEEDS REVIEW — see the outcome/reason code above and README's code table." -ForegroundColor Red
  exit 1
}
