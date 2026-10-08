# Safety Guidelines

SpaceKit removes files. That makes safety the most important property of the project, ahead of speed, features or convenience. This document is the contract: what SpaceKit will never do, how that's enforced, and what contributors must preserve.

> **The short version:** SpaceKit can never delete your disk, a volume, your home folder, your personal folders, system folders, credentials or repositories, and it never removes anything without showing you first. Automation is limited to what a rule recognises (regenerable data unless a job opts in to more) and folders you listed in the job, within a byte budget, and is journaled.

## 1. One gate for everything

Every removal, from every front end (the app, the TUI, the CLI and the background agent), passes through a single component: [`SafetyGuard`](../Sources/SpaceKitCore/Safety/SafetyGuard.swift). The `CleanupExecutor` asks the guard again **immediately before** touching each item, so a plan that was safe when it was reviewed is re-checked against the disk as it is at removal time. At that moment it also re-reads whether the item is or contains a git repository, and re-measures its size for the budget and the volume-share check.

The guard returns one of three decisions:

| Decision | Meaning |
|---|---|
| **allow** | May be removed. |
| **confirm** | May be removed only after a person explicitly acknowledges the shown warning. Never in automation. |
| **block** | Never removed, by anyone, in any mode. There is no override. |

**The checked folder is the folder that changes.** The executor resolves the item's parent folder first, and the guard judges both the path as given and that resolved folder plus the item's name. After the check, the executor opens the resolved folder with no symlinks allowed in any component, and the kernel's path for that handle must match it exactly. A parent swapped for a symlink in between makes the removal fail with nothing removed.

**Deletion never goes by path.** The item is removed by name relative to that handle. A folder is opened relative to its parent's handle without following symlinks, and its entries are removed by name. The removal keeps one folder open at a time, without recursion: it opens a subfolder by name, empties it, then climbs back through `..`, checks that it arrived in the folder it came from (same device and inode), and removes the emptied subfolder by name. If a folder was moved elsewhere during the removal, that check fails and the item stops with "… was moved while it was being removed; stopped there", instead of carrying on in the new parent. A subfolder swapped for a symlink during the removal is removed as a link, so the deletion never follows it out of the item. Because no step looks up a full path and only one folder is open at a time, neither the depth of the tree nor the open-file limit matters, and neither does losing search permission on a folder above.

**What can't be removed is left; everything else is removed.** An entry that can't be removed (an immutable file, say) stays, with the folders above it, and the removal carries on with the rest of the item. The item then fails with "Couldn't remove <first path>: <reason> (and N more)". What was deleted from an item that failed part way, for this reason or because a folder moved, is still written to the journal, charged to an automatic run's budget and counted in the bytes freed, and the failure says how much of it was deleted.

Moving to the Trash has no handle-based API, so for the Trash the parent is re-verified immediately before the move. A swap in the moment between that re-check and the move is the one race that remains.

## 2. Never: the whole disk, volumes and top-level folders

These are **blocked unconditionally** (`checkHardLimits`), regardless of configuration, confirmation or rules:

1. **The disk itself and every top-level folder:** `/`, `/System`, `/Users`, `/Applications`, `/Library`, `/private`, `/usr`, `/bin`, `/sbin`, `/etc`, `/var`, `/tmp`, `/opt`, `/Volumes`, `/cores`, `/dev`, and any path with fewer than two components.
2. **Volume roots and mount points:** `/Volumes/<anything>`, `/System/Volumes/<anything>` (Data, Preboot, VM, Update), any path that is a mount point, and **any folder that contains a mount point**.
3. **Anything that contains a protected location.** Removing `~/Library` would remove `~/Library/Keychains`, so `~/Library` is blocked. The same ancestor rule makes the home folder, `/Users` and `/` impossible to remove.
4. **The home folder and its structure:** `~`, `~/Library`, `~/Library/Application Support`, `~/Library/Containers`, `~/Library/Group Containers`, `~/Library/Caches`, `~/Library/Developer`, `~/Library/Preferences`, `~/Library/Keychains`, `~/Library/Mail`, `~/Library/Messages`, `~/Library/Calendars`, `~/Library/Photos`, `~/Library/Mobile Documents` (iCloud Drive), `~/Library/CloudStorage`, `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Pictures`, `~/Movies`, `~/Music`, `~/Public`, `~/Applications`, `~/Developer`, `~/.Trash`, `~/.config`, `~/.cache`, `~/.local`, `~/.docker`, `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`.
   *Things inside* folders like `~/Library/Caches` or `~/Downloads` can be removed (see the tiers below); the folders themselves cannot.
5. **Sealed trees, where neither the folder nor anything inside it is ever removed:** the operating system (`/System`, `/usr/bin`, `/usr/sbin`, `/usr/lib`, `/usr/libexec`, `/usr/share`, `/bin`, `/sbin`, `/private/etc`, `/private/var/db`), keychains, SSH/GPG/cloud credentials (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.config/gcloud`, `~/.config/gh`), Mail, Messages, Contacts, Calendars (including Calendar's group container), password managers (1Password, including 1Password 7, Bitwarden, Enpass, KeePassXC, Proton Pass, LastPass), and Docker Desktop's VM disk and group container (reclaim Docker space with Docker's own commands, never by deleting `Docker.raw`).
6. **Git metadata** (any path containing a `.git` component) and the **insides of library packages** such as `*.photoslibrary`, `*.musiclibrary` and keychains. Those are managed by their apps.
7. **Anything a `protected` rule describes** (databases, Docker volumes, photo libraries, credentials), and anything that contains it. For a rule whose path is a glob, that includes every folder a match could sit in, even before a match exists there.
8. **Your own protected paths** from `safety.protectedPaths`, plus their contents and ancestors, under the path as written and its location with symlinks resolved.
9. **Running as root.** SpaceKit refuses to remove anything, or run any tool command, when run with `sudo`.

**Spellings don't matter.** APFS treats `~/library`, `~/Library` and a differently normalized Unicode spelling as the same folder, so every comparison against these lists folds case and Unicode normalization (`PathUtil.comparisonKey`). On a case-sensitive volume this blocks more than strictly needed, never less. The guard checks each path as given, with symlinks in parent folders resolved, and (unless the item is itself a symlink) as it is spelled on disk.

Relative paths are refused, and so are `~name` paths: only `~` and `~/` are expanded. Paths are taken exactly as given, trailing spaces included, so `report ` is checked, measured and removed as `report `, never as `report`. `..` and symlinks in parent folders are resolved before checking, so a symlink can't smuggle a protected folder in under another name. Removing a symlink removes the link, never its target.

## 3. Tiers for everything else

| What | By hand (app, TUI, CLI) | Automatic jobs |
|---|---|---|
| 🟢 Rule item, `safe` (regenerable) | allow | allow, if inside the rule's locations |
| 🟡 Rule item, `review` | confirm | only if the job sets `includeReview: true`; moved to the Trash |
| 🔴 Rule item, `protected` | block | block |
| A git repository (`.git` directly inside) | confirm | block |
| Folder containing repositories | confirm (unless a 🟢 rule claims it) | block (unless a 🟢 rule claims it) |
| Personal data (Documents, Desktop, Downloads, Pictures, Movies, Music, iCloud, app containers) without a rule | confirm | only for a folder **listed in the job**, with `olderThan` ≥ 7 days **and** moving to the Trash |
| Anything no rule recognises | confirm | block, unless the folder is listed in the job; then moved to the Trash |
| A single item > 10% of the disk's used space | confirm | allowed up to 25%, blocked above |

"Inside the rule's locations" means under one of the rule's paths, or, for a pattern rule, a folder with a matching name under the rule's `roots` (or `scan.devRoots`) and outside its exclusions. Rule locations and job folders are resolved through symlinks, so this is judged on the item's location with symlinks in its parent folders resolved: `/tmp/x` counts as `/private/tmp/x`, and a symlinked parent that leads elsewhere takes the item out of scope. Every resolved spelling (including how the path is spelled on disk) must be inside, by hand and in automatic runs, and the same goes for folders listed in a job.

By hand, a rule speaks only inside its own locations. A name match elsewhere, such as a `node_modules` inside `~/.vscode/extensions`, counts as no rule: it needs confirmation like anything else no rule recognises. A `protected` rule blocks wherever it matches.

**Cleaning some rules gives each one what a full analysis would.** `clean <rule>`, `clean --safety`, `dev --rule` and jobs evaluate only some rules, and scan only those rules' locations. Every enabled rule and every `protected` rule still claims its share there, so a selected rule never gets anything another rule claims. That includes a job's own `paths:`: a `node_modules` inside a job folder stays unless the job lists the rule for it.

## 4. Automation limits

- **Never silently delete.** Jobs run in one of three modes: **observe** (notify only), **suggest** (prepare a plan and wait for approval) and **automatic**. New jobs default to *suggest*, except jobs created from 🟢 rules.
- An automatic run has a budget of **`safety.maxBytesPerRun`** (default 100 GB). An item that would take the run over what's left of the budget is skipped and reported. The budget is charged with each item's size measured at removal time, not the size in the plan, including files that also have a hard link outside the item. The freed bytes in the result and the journal leave those files out, because their data stays on disk under the other link.
- **Automatic permanent deletion is allowed only for 🟢 regenerable items.** Every other item an automatic run removes goes to the Trash, even when the job says `action: delete`. That includes folders you listed in the job, which have no rule. Things already in the Trash can only be deleted, so an automatic run deletes them only when a 🟢 rule covers them, and skips them otherwise.
- **Every automatic run that removes something, or leaves an item or a tool command skipped or failed, posts a notification.** This happens even with `automation.notifications: false`; that setting only silences observe and suggest runs.
- Every removal is written to the journal (`spacekit journal`) as it happens.
- **Confirmation is never implied.** Automatic runs never get the "confirmed" status, so anything that needs confirmation is skipped. When a person runs a job by hand (the app, the TUI, `spacekit jobs run --yes`), the core passes on only the confirmation that person gave; it never confirms a warning on their behalf.

### Tool commands

Rules can clean with the tool's own command (`docker builder prune`, `brew cleanup`, `xcrun simctl delete unavailable`) instead of removing files. Commands are held to the same standard as items:

- They run **without a shell**, with a 10-minute timeout. A tool still running then (or a child it left holding its output) gets SIGTERM, then SIGKILL, together with its process group.
- **The executable must be a bare name** such as `brew`: no `/`, no `..`, no `{name}` placeholder. Anything else is rejected when the rule is validated and again before it runs. The name is looked up in `PATH` plus the usual Homebrew, Cargo, Go, Bun, Docker and OrbStack locations, and relative `PATH` entries are ignored. The folder it is found in is resolved to its real location, but the executable keeps the name it was asked for. Multi-call tools such as rustup's proxies (`cargo` → `rustup`), mise shims and `bunx` decide what to do from the name they are run under, so resolving the name too would run a different program.
- **Built-in trust covers built-in rules only.** Rules from SpaceKit's own rule library may run the executables on the built-in trusted list (see [RULES.md](RULES.md#action)). A rule from any other folder runs a command only if its executable is in your `safety.allowedCommands`, whatever the trusted list says. A rule file you download can't run programs you haven't named. The built-in library is the folder `RuleLibrary.builtinDirectory` finds: `$SPACEKIT_RULES_DIR` if it is set, otherwise the app bundle's rules, the installed `share/spacekit/rules`, a `rules` folder beside the executable, or (debug builds only) the source checkout's `rules/`. Rules in that folder get built-in trust, so point `SPACEKIT_RULES_DIR` only at a library you trust.
- **The same gates as items:** refused when running as root, refused while the config is invalid (see §5), refused when the rule is `protected`, need confirmation by hand when the rule is `review`, and run automatically only for 🟢 rules or with `includeReview`. In an automatic run, a command whose estimated size exceeds what's left of the budget doesn't start, and what it actually freed is charged afterwards.
- **Per-item commands are checked like the item.** For an `itemCommand`, the item substituted for `{path}` and `{name}` goes through the guard like any other item and must be permitted.
- **A command runs only as its rule says now.** A planned command runs only if its rule is still loaded and still produces the same arguments. If the rule was disabled, removed or became invalid, or its command changed since the plan was made, the command is refused and the plan must be refreshed. An older suggestion therefore asks for a refresh instead of running a command its rule no longer gives.
- **AI models can be removed by their tool.** An `ai` rule may set `ai.removeCommand` (for example `ollama rm {name}`) for tools whose models share files. It goes through the same checks as `action.command`, and model names that start with `-` are refused. See [RULES.md](RULES.md).

## 5. Defaults that favour you

- **Preview first.** The CLI previews by default (`--yes` to act), the TUI and app always show a review screen listing every item with the guard's verdict and every reason it gave, each marked with the decision it calls for on its own. `--yes` confirms the warnings the preview printed. The TUI wraps long lines to the dialog and accepts `y` only after every line has been on screen; jumping to the end with End doesn't count the lines skipped. The app needs a ticked acknowledgement before it removes anything with a warning.
- **The Trash by default.** `safety.trash: always` is the default, so everything can be put back until you empty the Trash. With it, the CLI refuses `--permanent` and the app hides the delete option. Set `safety.trash: rules` to let regenerable caches be deleted directly.
- **A broken config stops cleaning.** If the config file exists but can't be read (including a symlink to a missing file, or a file other users can change; see [CONFIGURATION.md](CONFIGURATION.md#invalid-config)), read-only features keep working with the defaults and a warning, but every removal and tool command, manual or automatic, is refused with "Config file is invalid: … Fix it (spacekit config validate) before cleaning." The defaults would lack your protected paths, allowed commands and disabled rules, so they are never used to clean. The TUI's header and a banner in the app's main window say so for as long as the problem lasts.
- **Only valid rules are loaded.** A rule with a validation error is reported (`spacekit rules validate`) and not loaded. A rule in your folder can't take the place of a built-in `protected` rule, and can't replace a built-in rule with a lower safety level; the built-in rule stays. `rules.disabled` never turns off a `protected` rule. See [RULES.md](RULES.md#your-own-rules-and-overrides).
- **Only what you reviewed.** A confirmation covers only the warnings the preview showed. If the check at removal time raises a warning the preview didn't have (a repository appeared, the item grew past the volume-share limit), the item is skipped with "Changed since you reviewed it: …", listed with the run's result, and the run reports a problem (the CLI exits with status 1). Every plan records when it was made. Plain files directly in a folder ("Files in …" items) and entries in the Trash that were modified, created or moved there after that time weren't in the preview, so they are left alone. A "Files in …" item removes only the files it counted, never a file another rule claims in the same folder. A saved plan from before these checks (an old suggestion, or a "Files in …" item saved without its file names) can't remove loose files or Trash entries; refresh it. Removing an AI model stored as a cache removes the model's own entries, never the folder around them. Approving a suggestion evaluates its job again first and drops items that no longer meet the job's conditions.
- **Read-only scanning.** Scans read names, sizes and dates, and never read the contents of your files. The exceptions are small metadata files: Ollama's model manifests (JSON lists of the blobs each model uses, read to size models), the system's `/usr/share/firmlinks`, and SpaceKit's own config, rules and state. SpaceKit sends nothing anywhere.
- **Names can't rewrite the screen.** The CLI and TUI pass file names, paths, rule text and tool output through one sanitizer, `TerminalText.sanitize`, which shows control characters as visible escapes. A file named with an escape sequence can't hide or rewrite a line of a cleanup preview.
- **Journal.** `~/Library/Application Support/SpaceKit/journal.jsonl` records what was removed, when, how (`trash`, `delete` or `command`), by which rule or job, and where trashed items went. It is written one entry per removal as each happens, so an interrupted run still leaves a record, and each loose file gets its own entry. Quitting doesn't cut a cleanup short: the app and the TUI wait for a running cleanup, and the TUI holds SIGTERM, SIGHUP and SIGINT until it finishes, then exits. Deleting something already in the Trash is recorded as `delete`. A journal write that fails is reported with the run's result (and the CLI exits nonzero), never swallowed.

## 6. For contributors

- **The guard is the only gate.** New features that remove anything must go through `CleanupExecutor` (which calls the guard). The executor's own files in `Cleanup/` do the removing. `SafeRemoval`, which performs the handle-based removal described in §1, is module-internal and called only from `CleanupExecutor`'s files. Never call `FileManager.removeItem`, `trashItem`, `removefile`, `unlinkat` or `rm` anywhere else. The only exceptions are SpaceKit's own files: the temporary file `LockedFile.write` made next to one of SpaceKit's files when writing it fails, the LaunchAgent plist on `spacekit agent uninstall` (`LaunchAgent.uninstall`), and the `request` file in `SPACEKIT_DEBUG_DIR` once a debug build has read it (`DebugAutomation`). Tests remove their own `TempTree` folders.
- **Config can add protections, never remove them.** Don't add options that weaken the lists above.
- **`SPACEKIT_HOME` is for debug builds only.** It points the guard's idea of home at a sandbox, which would strip every home protection from the real home, so release builds ignore it (`PathUtil.home`).
- **Print untrusted text through `TerminalText.sanitize`.** That includes anything from the disk, a rule file or a tool's output that reaches a terminal.
- **Every guarantee has a test.** A change that makes any of them fail does not ship. Add a test for any new rule you introduce.
  - [`SafetyGuardTests`](../Tests/SpaceKitCoreTests/SafetyGuardTests.swift): the whole-disk, home, sealed-tree, repository, personal-folder, mount-point, symlink, root, `~name`, case and Unicode, protected-rule and volume-share rules, and the automation tiers.
  - [`CleanupExecutionTests`](../Tests/SpaceKitCoreTests/CleanupExecutionTests.swift): automatic runs trashing instead of deleting, items already in the Trash, the budget charged with measured sizes, repositories re-checked at removal time, the journal written per removal, the plan's creation time, warnings that are new at removal time, hard-linked files in freed bytes, the invalid-config refusal, symlinks and handle-based removal.
  - [`SafeRemovalTests`](../Tests/SpaceKitCoreTests/SafeRemovalTests.swift): a subfolder swapped for a symlink mid-removal, a folder moved out from above the walk, trees deeper than `PATH_MAX` and the open-file limit, a deep tree on a small stack, an entry that can't be removed, and a folder above without search permission.
  - [`PartialRemovalTests`](../Tests/SpaceKitCoreTests/PartialRemovalTests.swift): an item deleted only in part is reported, journaled and charged to the budget for what went.
  - [`SubsetEvaluationTests`](../Tests/SpaceKitCoreTests/SubsetEvaluationTests.swift): a rule or job evaluated on its own never gets what another rule claims.
  - [`CleanupCommandTests`](../Tests/SpaceKitCoreTests/CleanupCommandTests.swift): bare names, built-in trust and `allowedCommands`, the root, config, budget and per-item gates for tool commands, and the command timeout.
  - [`RuleLoadingTests`](../Tests/SpaceKitCoreTests/RuleLoadingTests.swift): overrides of built-in rules, protected rules that can't be disabled, and invalid rules that aren't loaded.
  - [`AutomationTests`](../Tests/SpaceKitCoreTests/AutomationTests.swift): no confirmation on a person's behalf, and notifications from automatic runs.
  - [`ConfigValueTests`](../Tests/SpaceKitCoreTests/ConfigValueTests.swift) and [`ConfigUpdateTests`](../Tests/SpaceKitCoreTests/ConfigUpdateTests.swift): strict ages and schedules, a config that doesn't parse is never overwritten, and config symlinks.
  - [`FileTrustTests`](../Tests/SpaceKitCoreTests/FileTrustTests.swift): config and rule files other users can change (by mode or access control list) aren't read, built-in rule owners, and SpaceKit's own files written with fixed modes whatever the umask.
  - [`PathUtilTests`](../Tests/SpaceKitCoreTests/PathUtilTests.swift) and [`TerminalTextTests`](../Tests/SpaceKitCoreTests/TerminalTextTests.swift): `SPACEKIT_HOME` ignored unless the build allows it, comparison keys, and the terminal sanitizer.
- **Rules must be honest.** If removing something costs a 20 GB download, it's `review`, even if it's "just a cache". See [RULES.md](RULES.md).
- **Debug hooks stay sandboxed.** The app's `SPACEKIT_DEBUG_DIR` automation (debug builds only) can only run cleanups whose every item lies inside a temporary sandbox home, never runs tool commands, and never confirms warnings, so it removes only items the guard allows outright. It deletes those items instead of moving them to the Trash, because the Trash is the real one outside the sandbox, and it refuses to run while the config sets `safety.trash: always`. A `snapshot=` value must be a bare file name inside the debug folder.

## Reporting a safety problem

If you find a way to make SpaceKit remove something it shouldn't, please report it privately to the maintainers rather than in a public issue, with the path, the command or steps, and `spacekit doctor` output.
