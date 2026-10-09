# SpaceKit developer tasks. Run `make help` for a list.

PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
SHAREDIR := $(PREFIX)/share/spacekit
SWIFT ?= swift
# The Command Line Tools lack two macro plugins SwiftPM gets from Xcode. SwiftUI's is avoided by building with
# an older SDK (scripts/swift-sdk.sh). Swift Testing's ships with them but SwiftPM doesn't load it, so it's
# passed by path.
DEVELOPER_DIR_PATH := $(shell xcode-select -p)
ifneq ($(findstring /CommandLineTools,$(DEVELOPER_DIR_PATH)),)
ifeq ($(origin SDKROOT),undefined)
SDKROOT := $(shell scripts/swift-sdk.sh)
endif
SWIFT_FLAGS += -Xswiftc -plugin-path -Xswiftc $(DEVELOPER_DIR_PATH)/usr/lib/swift/host/plugins/testing
endif
ifneq ($(SDKROOT),)
export SDKROOT
endif
# The background agent's plist. `make uninstall` reads it to see which executable the agent runs.
AGENT_PLIST ?= $(HOME)/Library/LaunchAgents/dev.spacekit.agent.plist

.PHONY: help build release test app run tui install uninstall lint format validate-rules clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Debug build of everything
	$(SWIFT) build $(SWIFT_FLAGS)

release: ## Optimised build of the CLI and app
	$(SWIFT) build -c release

test: ## Run the test suite (includes the safety guarantees)
	$(SWIFT) test $(SWIFT_FLAGS)

app: ## Build build/SpaceKit.app (release, ad-hoc signed)
	scripts/build-app.sh

run: ## Run the app from source
	$(SWIFT) run $(SWIFT_FLAGS) SpaceKitApp

tui: ## Run the terminal UI from source on your home folder
	$(SWIFT) run $(SWIFT_FLAGS) spacekit tui ~

install: release ## Install the CLI to $(BINDIR) (the built-in rules are compiled into it)
	@mkdir -p "$(BINDIR)"
	install -m 755 "$$($(SWIFT) build -c release --show-bin-path)/spacekit" "$(BINDIR)/spacekit"
	@echo "Installed $(BINDIR)/spacekit. Make sure $(BINDIR) is on your PATH, then try: spacekit doctor"

# $(SHAREDIR) holds the rule library older versions installed; nothing reads it any more.
uninstall: ## Stop the background agent if it runs this CLI, remove the installed CLI (your config and history stay)
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

validate-rules: build ## Validate every built-in rule (rebuilt from rules/) and your own
	$(SWIFT) run $(SWIFT_FLAGS) spacekit rules validate

lint: ## Check formatting with swift-format
	swift-format lint --recursive --strict Sources Tests

format: ## Format sources with swift-format
	swift-format format --recursive --in-place Sources Tests

clean: ## Remove build products
	rm -rf .build build
