.DEFAULT_GOAL := help
.PHONY: help build build-release bundle sign make-dmg dist appcast install cert-setup run-app run-cli test test-core test-ui clean resolve kill-build install-vscode install-cursor uninstall

# Colors
CYAN   := \033[36m
DIM    := \033[2m
BOLD   := \033[1m
RESET  := \033[0m

help:
	@printf "$(BOLD)seshctl$(RESET) $(DIM)commands$(RESET)\n\n"
	@printf "  $(DIM)build$(RESET)\n"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "build" "Build debug"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "build-release" "Build release"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "bundle" "Assemble dist/Seshctl.app from release build (no signing)"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "sign" "Sign dist/Seshctl.app with self-signed cert"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "make-dmg" "Create dist/Seshctl-<VERSION>.dmg from signed app"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "dist" "Full release artifact: bundle + sign + make-dmg"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "install" "Build + sign + drop Seshctl.app into /Applications and relaunch"
	@echo ""
	@printf "  $(DIM)setup$(RESET)\n"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "cert-setup" "Create the Seshctl Self-Signed code-signing identity (one-time)"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "install-vscode" "Build + install VS Code extension"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "install-cursor" "Build + install Cursor extension"
	@echo ""
	@printf "  $(DIM)run$(RESET)\n"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "run-app" "Run app (debug)"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "run-cli" "Run CLI (debug), e.g. make run-cli ARGS=\"list\""
	@echo ""
	@printf "  $(DIM)test$(RESET)\n"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "test" "Run all tests"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "test-core" "Run SeshctlCore tests"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "test-ui" "Run SeshctlUI tests"
	@echo ""
	@printf "  $(DIM)remove$(RESET)\n"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "uninstall" "Remove all seshctl integrations and trash /Applications/Seshctl.app"
	@echo ""
	@printf "  $(DIM)maintenance$(RESET)\n"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "clean" "Clean build artifacts"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "resolve" "Resolve package dependencies"
	@printf "  $(CYAN)%-14s$(RESET) %s\n" "kill-build" "Force-kill stale SwiftPM processes"
	@echo ""

build:
	swift build

build-release:
	swift build -c release

bundle:
	bash scripts/build-app-bundle.sh

sign:
	bash scripts/sign-app.sh

make-dmg:
	bash scripts/make-dmg.sh

dist: bundle sign make-dmg

# Sparkle appcast regeneration. Intentionally NOT chained into `make dist`
# so dist stays testable in isolation. Run after `make dist` to sign the
# new DMG with EdDSA and rewrite docs/appcast.xml for GitHub Pages.
# See docs/release.md for the full release flow.
appcast:
	bash scripts/make-appcast.sh

# Dev iteration: rebuild + sign + drop the .app straight into /Applications.
# Skips DMG creation (use `make dist` for the user-facing flow). Designed
# for tight iteration on app code; preserves the marker file in
# ~/Library/Application Support/Seshctl so the welcome panel doesn't re-fire.
#
# Hook + symlink + marker refresh happens automatically on the next launch:
# AppDelegate.runFirstLaunchInstallerIfNeeded compares the marker against the
# running bundle, and the freshly-copied bundle's SeshctlApp mtime is newer
# than the marker's installedAt timestamp, so FirstLaunchInstaller.install
# fires silently. No welcome panel, no manual `seshctl install` step.
#
# To force the welcome panel on next launch, run `seshctl uninstall` (or
# trash the marker file) before `make install`.
install: bundle sign
	@pkill -f 'Seshctl.app/Contents/MacOS/SeshctlApp' 2>/dev/null || true
	@sleep 0.3
	@if [ -d /Applications/Seshctl.app ]; then \
		trash /Applications/Seshctl.app 2>/dev/null || rm -rf /Applications/Seshctl.app; \
	fi
	cp -R dist/Seshctl.app /Applications/Seshctl.app
	open /Applications/Seshctl.app
	@echo ""
	@printf "  $(BOLD)Seshctl installed$(RESET) and relaunched from /Applications.\n"
	@echo ""

cert-setup:
	bash scripts/generate-self-signed-cert.sh

run-app:
	swift run SeshctlApp

run-cli:
	swift run seshctl-cli $(ARGS)

test:
	swift test

test-core:
	swift test --filter SeshctlCoreTests

test-ui:
	swift test --filter SeshctlUITests

install-vscode:
	cd vscode-extension && npm install && npm run build
	cd vscode-extension && npm exec -- @vscode/vsce package --allow-missing-repository
	code --install-extension vscode-extension/seshctl-*.vsix
	rm vscode-extension/seshctl-*.vsix
	@echo "VS Code extension installed — reload VS Code to activate"

install-cursor:
	@command -v cursor >/dev/null 2>&1 || { echo "error: 'cursor' CLI not found on PATH. Install Cursor first: brew install --cask cursor"; exit 1; }
	cd vscode-extension && npm install && npm run build
	cd vscode-extension && npm exec -- @vscode/vsce package --allow-missing-repository
	cursor --install-extension vscode-extension/seshctl-*.vsix
	rm vscode-extension/seshctl-*.vsix
	@echo "Cursor extension installed — reload Cursor to activate"

uninstall:
	@if command -v seshctl >/dev/null 2>&1; then \
		seshctl uninstall; \
	elif command -v seshctl-cli >/dev/null 2>&1; then \
		seshctl-cli uninstall; \
	else \
		echo "seshctl CLI not found on PATH — already uninstalled?"; \
	fi
	@pkill -f 'Seshctl.app/Contents/MacOS/SeshctlApp' 2>/dev/null || true
	@sleep 0.3
	@if [ -d /Applications/Seshctl.app ]; then \
		trash /Applications/Seshctl.app 2>/dev/null || rm -rf /Applications/Seshctl.app; \
		echo "trashed /Applications/Seshctl.app"; \
	fi

clean:
	swift package clean

resolve:
	swift package resolve

kill-build:
	pkill -9 -f swift-build || true
	pkill -9 -f swift-test || true
	pkill -9 -f swift-frontend || true
	@echo "killed stale SwiftPM processes"
