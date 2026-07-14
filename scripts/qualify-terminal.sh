#!/bin/bash
# Qualify a terminal for StickShift: runs the two machine-verifiable gates
# (AX read path, synthetic-keystroke delivery) against any terminal app.
# This is exactly the procedure that verified Terminal.app on 2026-07-13.
#
#   ./scripts/qualify-terminal.sh "iTerm"            # app name, or
#   ./scripts/qualify-terminal.sh com.googlecode.iterm2   # bundle id
#
# A failed qualification cannot damage anything: gate 1 is read-only, and
# gate 2 types a harmless probe string into a window that is only running
# `cat` + `sleep`. Gates 3-4 (live agent session) remain manual; see AGENTS.md.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ARG="${1:-}"
[ -n "$ARG" ] || { echo "usage: $0 <app-name-or-bundle-id>"; exit 2; }

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '    \033[31m✗ %s\033[0m\n' "$1"; }

# Resolve bundle id and app name from either form
if [[ "$ARG" == *.* && "$ARG" != *" "* ]]; then
  BUNDLE="$ARG"
  APPNAME="$(osascript -e "name of application id \"$BUNDLE\"" 2>/dev/null || echo "$ARG")"
else
  APPNAME="$ARG"
  BUNDLE="$(osascript -e "id of application \"$APPNAME\"" 2>/dev/null)" \
    || { bad "cannot resolve bundle id for \"$APPNAME\""; exit 2; }
fi
echo "terminal: $APPNAME ($BUNDLE)"

step "Building probes"
make -C "$REPO" bin/inject_probe >/dev/null
make -C "$REPO" >/dev/null
ok "bin/shift + bin/inject_probe ready"

step "Gate 1 of 2: AX read path (read-only)"
cat <<EOT
    In $APPNAME, open a NEW window/tab and run:

      clear; cat "$REPO/tests/fixtures/fakepane.txt"; sleep 300

    (renders agent-style chrome for the classifier; the sleep keeps it on screen)
EOT
read -rp "    Press Enter when that window is showing the fake pane... "
PID="$(osascript -e "tell application \"System Events\" to unix id of first process whose bundle identifier is \"$BUNDLE\"" 2>/dev/null || pgrep -xn "$APPNAME" || true)"
[ -n "$PID" ] || { bad "cannot find $APPNAME's pid (is it running?)"; exit 1; }
TMPCONF="$(mktemp)"; trap 'rm -f "$TMPCONF"' EXIT
printf 'enabled_terminals = ["%s"]\n' "$BUNDLE" > "$TMPCONF"; chmod 600 "$TMPCONF"
OUT="$(STICKSHIFT_CONFIG="$TMPCONF" "$REPO/bin/shift" status --pid "$PID" || true)"
echo "$OUT" | sed 's/^/      /'
if echo "$OUT" | grep -q "agent            : claude" && echo "$OUT" | grep -q "model            : Fable 5"; then
  ok "gate 1 PASSED: $APPNAME exposes pane text via Accessibility"
else
  bad "gate 1 FAILED: the classifier could not read the pane."
  echo "    $APPNAME does not expose usable text via AX. STOP: this terminal would"
  echo "    need the OCR fallback; it is not qualifiable this way."
  exit 1
fi

step "Gate 2 of 2: synthetic-keystroke delivery"
echo "    Click the fake-pane window in $APPNAME so it has keyboard focus."
read -rp "    Press Enter within 5 seconds of focusing it... "
sleep 1
RES="$("$REPO/bin/inject_probe" "$PID" || true)"
if [ "$RES" = "DELIVERED" ]; then
  ok "gate 2 PASSED: keystrokes deliver (verified by occurrence-count proof)"
else
  bad "gate 2 FAILED ($RES): $APPNAME drops synthetic keystrokes. STOP: not drivable."
  exit 1
fi

step "Result"
cat <<EOT
    $APPNAME passed both machine-verifiable gates. To enable it:

      1. Add to ~/.stickshift/config.toml:
           enabled_terminals = ["dev.warp.Warp-Stable", "$BUNDLE"]
      2. Finish qualification against a LIVE agent session (gates 3-4 in
         AGENTS.md): a dry-run "shift 4", then "shift 4 --commit" against a
         throwaway session, verifying the pane switched.
      3. You can close the fake-pane window now.

    Consider a PR updating the supported-terminals table in README.md.
EOT
