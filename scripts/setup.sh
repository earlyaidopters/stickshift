#!/bin/bash
# StickShift one-shot installer for macOS.
# Idempotent: safe to re-run at any point; every step checks before acting.
# What it does: prerequisites -> signing identity -> build -> test -> install ->
# launch -> print the (one-time) Accessibility instructions.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="StickShift Dev"
APP="$HOME/Applications/StickShift.app"

step()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()    { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn()  { printf '    \033[33m!\033[0m %s\n' "$1"; }
die()   { printf '    \033[31m✗ %s\033[0m\n' "$1"; exit 1; }

# ---------- 1. prerequisites ----------
step "Checking prerequisites"
[ "$(uname -s)" = "Darwin" ] || die "StickShift is macOS-only (see docs/WINDOWS.md for the port status)"
if ! xcode-select -p >/dev/null 2>&1; then
  warn "Xcode command line tools missing; requesting install (a dialog will appear)"
  xcode-select --install || true
  die "Re-run this script after the command line tools finish installing"
fi
ok "clang $(clang --version | head -1 | sed 's/.*version //;s/ .*//')"

# ---------- 2. signing identity (stable TCC identity across rebuilds) ----------
step "Checking code-signing identity \"$IDENTITY\""
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$IDENTITY"; then
  ok "identity already in the login keychain"
else
  warn "creating a self-signed \"$IDENTITY\" certificate (10-year, local only)"
  warn "macOS may prompt for your login password once, to trust it for code signing"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
  # OpenSSL 3 needs -legacy for a keychain-readable p12; LibreSSL has no such flag
  openssl pkcs12 -export -legacy -out "$TMP/ss.p12" -inkey "$TMP/key.pem" \
      -in "$TMP/cert.pem" -name "$IDENTITY" -passout pass:sstemp 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/ss.p12" -inkey "$TMP/key.pem" \
      -in "$TMP/cert.pem" -name "$IDENTITY" -passout pass:sstemp
  security import "$TMP/ss.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P sstemp -T /usr/bin/codesign >/dev/null
  security add-trusted-cert -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"
  security find-identity -p codesigning -v | grep -q "$IDENTITY" \
    || die "identity did not become valid; open Keychain Access and check \"$IDENTITY\""
  ok "identity created and trusted"
fi

# ---------- 3. build + test ----------
step "Building"
make -C "$REPO" >/dev/null
ok "bin/shift and bin/StickShift built"

step "Running the test suite"
if make -C "$REPO" test 2>&1 | tail -1 | grep -q "ALL PASS"; then
  ok "all tests pass"
else
  make -C "$REPO" test | tail -20
  die "test suite failed; fix before installing"
fi

step "Verifying this machine's agents (pipeline matrix)"
if make -C "$REPO" matrix 2>&1 | tail -1 | grep -q "ALL PASS"; then
  ok "installed agent binaries qualify; all 65 UI combinations pass"
else
  make -C "$REPO" matrix | grep -E "FAIL|qualified=0" | head -10
  warn "matrix reported failures — likely an unqualified agent version."
  warn "See 'Agent qualification' in README.md; shifts will refuse until fixed."
fi

# ---------- 4. install + launch ----------
step "Installing StickShift.app"
make -C "$REPO" install-app | grep -E "signed|WARNING" || true
codesign -dvv "$APP" 2>&1 | grep -q "Authority=$IDENTITY" \
  || warn "app is NOT signed with $IDENTITY — the Accessibility grant will not survive reinstalls"
ok "installed to $APP"

step "Launching"
pkill -x StickShift 2>/dev/null && sleep 1 || true
open "$APP"
ok "running"

# ---------- 5. the one manual step ----------
step "Accessibility (one-time)"
cat <<'EOT'
    StickShift just asked macOS for Accessibility permission. To finish:

      1. In the dialog, click "Open System Settings"
         (or go to System Settings > Privacy & Security > Accessibility)
      2. Turn ON the StickShift toggle
      3. Quit and reopen StickShift once (right-click the menu-bar gear > Quit,
         then relaunch). Grants only attach at process launch.

    Because the app is signed with a stable identity, this grant survives every
    future rebuild and reinstall. You will never do this again.

    Verify:  focus a terminal pane running Claude Code or Codex, then run
             ./bin/shift status   from another pane, or just pull a gear.
    Logs:    ~/.stickshift/log  (every attempt, with a reason code)
EOT
