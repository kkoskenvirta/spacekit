# SpaceKit developer tasks. Run `make help` for a list.

PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
SHAREDIR := $(PREFIX)/share/spacekit
SWIFT ?= swift
# The background agent's plist. `make uninstall` reads it to see which executable the agent runs.
AGENT_PLIST ?= $(HOME)/Library/LaunchAgents/dev.spacekit.agent.plist

.PHONY: help build release test app run tui install uninstall lint format validate-rules clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Debug build of everything
	$(SWIFT) build

release: ## Optimised build of the CLI and app
	$(SWIFT) build -c release

test: ## Run the test suite (includes the safety guarantees)
	$(SWIFT) test

app: ## Build build/SpaceKit.app (release, ad-hoc signed)
	scripts/build-app.sh

run: ## Run the app from source
	$(SWIFT) run SpaceKitApp

tui: ## Run the terminal UI from source on your home folder
	$(SWIFT) run spacekit tui ~

install: release ## Install the CLI to $(BINDIR) and the rule library to $(SHAREDIR)
	@mkdir -p "$(BINDIR)" "$(SHAREDIR)"
	install -m 755 "$$($(SWIFT) build -c release --show-bin-path)/spacekit" "$(BINDIR)/spacekit"
	rm -rf "$(SHAREDIR)/rules" && cp -R rules "$(SHAREDIR)/rules"
	@echo "Installed $(BINDIR)/spacekit. Make sure $(BINDIR) is on your PATH, then try: spacekit doctor"

uninstall: ## Stop the background agent if it runs this CLI, remove the installed CLI and rules (your config and history stay)
	@program=$$([ -f "$(AGENT_PLIST)" ] && /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$(AGENT_PLIST)" 2>/dev/null); \
	installed=$$(realpath "$(BINDIR)/spacekit" 2>/dev/null); \
	if [ -z "$$program" ]; then :; \
	elif [ -x "$(BINDIR)/spacekit" ] && { [ "$$program" = "$(BINDIR)/spacekit" ] || [ "$$program" = "$$installed" ]; }; then \
		"$(BINDIR)/spacekit" agent uninstall || true; \
	else \
		echo "Leaving the background agent installed: it runs $$program, not $(BINDIR)/spacekit."; \
	fi
	rm -f "$(BINDIR)/spacekit"
	rm -rf "$(SHAREDIR)"

validate-rules: build ## Validate every rule file
	$(SWIFT) run spacekit rules validate

lint: ## Check formatting with swift-format
	swift-format lint --recursive --strict Sources Tests

format: ## Format sources with swift-format
	swift-format format --recursive --in-place Sources Tests

clean: ## Remove build products
	rm -rf .build build
