# Contributing to SpaceKit

Thanks for helping developers get their disks back. The easiest high-impact contribution is a **storage rule**: if a tool you use leaves gigabytes somewhere, teach SpaceKit about it.

## Setup

Requirements: macOS 15+, Xcode 16+ (Swift 6).

```sh
git clone <your fork> && cd spacekit
make build          # debug build
make test           # the test suite, including the safety guarantees
make run            # the app from source
make tui            # the terminal UI on ~
swift run spacekit --help
```

`make app` builds `build/SpaceKit.app`, and `make install` puts the CLI in `~/.local/bin` (override with `PREFIX=…`).

### Running the tests

`make test` runs `swift test`. With only the Command Line Tools, plain `swift build` and `swift test` miss two macro plugins. The macOS 27 SDK's SwiftUI `@State` needs a plugin that ships only with Xcode, so `make` and `scripts/build-app.sh` build with the newest installed SDK that compiles it ([`scripts/swift-sdk.sh`](scripts/swift-sdk.sh)). The Swift Testing plugin ships with the Command Line Tools, but SwiftPM doesn't load it, so `make` passes its path to the compiler. Use the `make` targets, or copy the flags from the [`Makefile`](Makefile). CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) builds everything, runs the tests, validates the rules and bundles the app on macOS 15. It is the source of truth for the app target, so a change to `Sources/SpaceKitApp` isn't verified until CI passes.

### A sandbox for manual testing

While developing, point SpaceKit at a throwaway home, config and state so you don't touch your own:

```sh
export SPACEKIT_SANDBOX=$(mktemp -d)    # a new folder only your account can write, under /var/folders
export SPACEKIT_HOME=$SPACEKIT_SANDBOX/home SPACEKIT_CONFIG=$SPACEKIT_SANDBOX/config.yaml SPACEKIT_STATE_DIR=$SPACEKIT_SANDBOX/state
```

- **Use a folder of your own, not a fixed path in `/tmp`.** `/tmp` is shared by every account on the Mac, so another account could create `/tmp/sk` or `/tmp/sk/config.yaml` before you do. SpaceKit reads a config or rule file only if you (or root) own it, group and others can't write to it, its folder isn't writable by group or others without the sticky bit, and neither has an access control list that lets anyone else change it (see [Invalid config](docs/CONFIGURATION.md#invalid-config)). A sandbox in a shared folder can therefore fail with a config error or rules that aren't loaded. A `mktemp -d` folder meets these rules, and so do the files SpaceKit writes there itself (0644, folders 0755, whatever your umask). Fixture files you write by hand under a umask such as 002 come out group-writable; `chmod 644` them. The background agent also keeps the `SPACEKIT_CONFIG` and `SPACEKIT_STATE_DIR` it was installed with, so don't install the agent from a sandbox shell.

- **`SPACEKIT_HOME` works in debug builds only.** It moves SpaceKit's idea of the home folder, and with it the default config and state locations and every home protection, to a sandbox folder. Release builds (`make app`, `make install`, `swift build -c release`) ignore it, so it can never strip the protections from your real home.
- **Either spelling works.** `/var/folders/…` and `/private/var/folders/…` (or `/tmp` and `/private/tmp`) name the same folder. Rule paths, pattern roots, job paths and the debug sandbox home are resolved through symlinks before they're compared, so either spelling matches what a scan finds. The safety guard judges whether an item is inside a rule's or a job's locations by where its parent folders' symlinks lead, so an item spelled `/tmp/…` keeps its rule's recognition; the resolved location still has to be in scope.
- **Keep the real Trash out of it.** Moving to the Trash uses macOS's Trash, whatever the sandbox, so anything you clean with the default `safety.trash: always` lands in your own `~/.Trash`. To test removals without that, set `safety.trash: rules` in the sandbox config and give your fixture rules `safety: { level: safe, trash: false }` and `action: remove`, with paths inside the sandbox. A cleanup made only of such rules deletes directly. Everything else still goes to the Trash: 🟡 review items, folders no rule recognises, items marked in the TUI's or the app's map, and paths you name on `spacekit clean` (unless you pass `--permanent`). Keep fixtures 🟢 and clean them from Dev Intelligence or by rule id.

## Adding or fixing a rule

Built-in rules are compiled into SpaceKit: the `EmbedRules` build plugin ([`Plugins/EmbedRules`](Plugins/EmbedRules)) turns every `rules/**/*.yaml` into Swift source for `SpaceKitCore` on each build, so an edit takes effect when you rebuild, and nothing reads `rules/` at run time.

1. Find the right file in [`rules/`](rules), or add one (`rules/<area>/<tool>.yaml`).
2. Follow [docs/RULES.md](docs/RULES.md). Be precise about paths, honest about safety, and say in the description what happens if it's removed.
3. Validate and try it:
   ```sh
   swift run spacekit rules validate --builtin rules/developer/mytool.yaml   # this file, judged as a built-in rule
   swift run spacekit rules validate                # rebuilds, then checks every built-in rule and your own
   swift run spacekit dev --rule mytool.cache --items 20
   swift run spacekit clean mytool.cache          # preview only; nothing is removed without --yes
   ```
   `swift test` fails when any built-in rule doesn't parse or has an error (`BuiltinRulesTests`). In a debug build, `SPACEKIT_RULES_DIR=<folder>` replaces the compiled-in rules with that folder's, to try edits without rebuilding; release builds ignore it.
4. In the PR, say which tool versions and macOS version you checked the paths on.

## Code

- **Safety first.** Read [docs/SAFETY.md](docs/SAFETY.md). Anything that removes files goes through `CleanupExecutor` and `SafetyGuard`, and needs tests. Never weaken a built-in protection. Text from the disk, rule files or tools that reaches a terminal goes through `TerminalText.sanitize`.
- **Performance matters.** The scanner and the rule engine run over millions of entries. Measure before and after (release builds: `swift build -c release`), and prefer incremental updates over recomputation (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- **Core stays UI-free.** `SpaceKitCore` must not import AppKit or SwiftUI, so the CLI, TUI and agent share it.
- **Style.** Swift 6 language mode, strict concurrency, `swift-format` (`make lint`, `make format`). Match the surrounding code; comments explain *why*.
- **Tests** use Swift Testing (`import Testing`). File-system tests use `TempTree` and never touch real user data. Every cleanup test builds its executor with `sandboxExecutor` ([`CleanupExecutionTests.swift`](Tests/SpaceKitCoreTests/CleanupExecutionTests.swift)), which puts the home and the journal inside the `TempTree` and moves "trashed" items into its own `.Trash` with `sandboxTrash` ([`TestSupport.swift`](Tests/SpaceKitCoreTests/TestSupport.swift)), so nothing reaches your real Trash. Tests that run the executor a `SpaceKitContext` builds set its `trash` to `sandboxTrash` first, and tests that move items to a Trash themselves use `sandboxTrash` too. Tests that change the umask do it through `withUmask`, because the umask is shared by every test running at the same time.

## UI screenshots (debug builds)

Debug builds of the app can be driven without Screen Recording permission, which helps when reviewing UI changes:

```sh
mkdir -p "$SPACEKIT_SANDBOX/shots"
SPACEKIT_DEBUG_DIR=$SPACEKIT_SANDBOX/shots swift run SpaceKitApp &
printf 'scan=~/Library/Developer\n' > "$SPACEKIT_SANDBOX/shots/request"
printf 'section=dev\nsnapshot=dev.png\n' > "$SPACEKIT_SANDBOX/shots/request"      # → $SPACEKIT_SANDBOX/shots/dev.png
```

Supported keys: `section`, `visualization`, `color`, `depth`, `scan`, `focus`, `select`, `hover`, `sheet` (`onboarding`, `safety`, `job`, `cleanup`, `cleanup:<rule-id>`, `settings`), `close`, `snapshot` (a bare file name, saved in the debug folder). `confirm-cleanup` runs the open cleanup only when `SPACEKIT_HOME` resolves to a temporary sandbox under `/private/tmp` or `/private/var/folders`, every item lies inside it, the plan has no tool commands and the config doesn't set `safety.trash: always`. It never confirms warnings, so it removes only items the guard allows outright, such as items of a 🟢 rule, and it deletes them instead of moving them to your real Trash.

## Reporting bugs

Include `spacekit doctor` output, macOS version, and for scan results, `spacekit scan <path> --json`. Report safety problems privately (see [docs/SAFETY.md](docs/SAFETY.md#reporting-a-safety-problem)).
