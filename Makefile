# StickShift build. ObjC engine (Swift toolchain temporarily broken; see
# findings/spike-00-toolchain.md). Frameworks are identical either way.
CC = clang
FRAMEWORKS = -framework Foundation -framework AppKit -framework ApplicationServices \
             -framework CoreGraphics -framework Carbon -framework Security \
             -framework ScreenCaptureKit -framework Vision
CFLAGS = -fobjc-arc -Wall -O2 -Isrc/core
CORE = src/core/Proc.m src/core/AXState.m src/core/Manifest.m src/core/Inject.m \
       src/core/Config.m src/core/Attribution.m src/core/Protocol.m src/core/Switch.m
CLI = src/cli/main.m

APP = src/app/AppDelegate.m src/app/main.m
APPFW = $(FRAMEWORKS) -framework WebKit

all: bin/shift bin/StickShift

bin/shift: $(CORE) $(CLI) | bin
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(CORE) $(CLI) -o bin/shift

bin/StickShift: $(CORE) $(APP) src/app/gearbox.html | bin
	$(CC) $(CFLAGS) -Isrc/app $(APPFW) $(CORE) $(APP) -o bin/StickShift
	cp src/app/gearbox.html bin/gearbox.html

bin:
	mkdir -p bin

.PHONY: test e2e clean app install-app matrix install-cli

# Put the CLI on PATH as `stickshift` (NOT `shift` — that name loses to the shell
# builtin in every POSIX shell, interactively and in scripts). Prefers the Homebrew
# prefix (user-writable on Apple silicon), falls back to /usr/local/bin.
CLIDIR ?= $(shell brew --prefix 2>/dev/null || echo /usr/local)/bin
install-cli: bin/shift
	@mkdir -p $(CLIDIR) 2>/dev/null || true
	@ln -sf "$(CURDIR)/bin/shift" "$(CLIDIR)/stickshift" \
	  && echo "Linked $(CLIDIR)/stickshift -> bin/shift" \
	  || echo "Cannot write $(CLIDIR); re-run as: sudo make install-cli  (or CLIDIR=~/bin make install-cli)"
test: bin/shift
	./tests/run_tests.sh

# Live-machine verification: qualifies THIS machine's installed agent binaries and
# pushes every (model, effort) combination through the offline pipeline stages.
# Run after install and after qualifying a new agent version or terminal.
matrix: bin
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(CORE) tests/matrix_probe.m -o bin/matrix_probe
	./bin/matrix_probe

# Keystroke-delivery probe used by scripts/qualify-terminal.sh (gate 2).
bin/inject_probe: $(CORE) tests/inject_probe.m | bin
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(CORE) tests/inject_probe.m -o bin/inject_probe

# Proper double-clickable menu-bar app (Spotlight-launchable, no terminal needed).
# Signed with the self-signed "StickShift Dev" identity (login keychain, created
# 2026-07-13): the designated requirement is identifier+cert, STABLE across builds,
# so the Accessibility grant survives install-app. Ad-hoc (-s -) keys TCC to the
# cdhash instead, which rotates every build and silently orphans the grant. If the
# identity is missing (fresh machine), we fall back to ad-hoc and warn.
SIGN_ID ?= StickShift Dev
APPBUNDLE = dist/StickShift.app
app: bin/StickShift
	rm -rf $(APPBUNDLE)
	mkdir -p $(APPBUNDLE)/Contents/MacOS $(APPBUNDLE)/Contents/Resources
	cp bin/StickShift $(APPBUNDLE)/Contents/MacOS/StickShift
	cp src/app/Info.plist $(APPBUNDLE)/Contents/Info.plist
	cp src/app/gearbox.html $(APPBUNDLE)/Contents/Resources/gearbox.html
	cp src/app/StickShift.icns $(APPBUNDLE)/Contents/Resources/StickShift.icns
	@codesign --force -s "$(SIGN_ID)" $(APPBUNDLE) 2>/dev/null \
	  && echo "signed with identity: $(SIGN_ID)" \
	  || { echo "WARNING: identity '$(SIGN_ID)' unavailable — ad-hoc signing (TCC grant will rotate)"; \
	       codesign --force -s - $(APPBUNDLE); }

install-app: app
	mkdir -p ~/Applications
	rm -rf ~/Applications/StickShift.app
	cp -R $(APPBUNDLE) ~/Applications/StickShift.app
	@echo "Installed ~/Applications/StickShift.app — grant Accessibility on first run."

# Live end-to-end helper (run yourself in a scratch pane; needs a focused agent):
# 1. In Warp, open a NEW pane and start `claude` in a throwaway dir with an EMPTY input.
# 2. Keep that pane focused, then from ANOTHER pane run: make e2e GEAR=4
# The engine refuses SELF_TARGET if you run it from the same pane, by design.
e2e: bin/shift
	@echo "Focus a scratch agent pane, then this will dry-run then commit gear $(GEAR):"
	./bin/shift $(GEAR)
	@echo "--- committing in 3s (Ctrl-C to abort) ---"; sleep 3
	./bin/shift $(GEAR) --commit

clean:
	rm -rf bin
