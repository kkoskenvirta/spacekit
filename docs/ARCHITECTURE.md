# Architecture

SpaceKit is one Swift package with a shared core and three front ends.

```
┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐
│ SpaceKitApp  │  │ spacekit CLI │  │ SpaceKitTUI              │
│ SwiftUI      │  │ ArgumentParser│ │ raw-mode terminal UI     │
└──────┬───────┘  └──────┬───────┘  └────────────┬─────────────┘
       └─────────────────┼───────────────────────┘
                 ┌───────▼────────────────────────────────────────┐
                 │ SpaceKitCore                                   │
                 │  Scanner ─ Layout ─ Rules ─ Intelligence       │
                 │  SafetyGuard ─ Cleanup ─ Automation ─ History  │
                 └────────────────────────────────────────────────┘
                         ▲ rules/*.yaml (compiled in)   ▲ ~/.config/spacekit/config.yaml
```

| Target | Role |
|---|---|
| `SpaceKitCore` | Everything that isn't UI. No AppKit/SwiftUI. |
| `SpaceKitTUI` | Full-screen terminal interface (`spacekit tui`), plus ANSI helpers the CLI shares. |
| `SpaceKitCLI` → `spacekit` | Every capability as a command; also the background agent (`spacekit agent run`). |
| `SpaceKitApp` | The macOS app. Bundled by `scripts/build-app.sh` with the CLI in `Contents/Helpers`. |
| `EmbedRules` plugin + `RuleEmbedder` | Build tool plugin on `SpaceKitCore`: on every build, `RuleEmbedder` writes the text of each `rules/**/*.yaml` into a generated Swift source (`EmbeddedRuleFiles`). Each rule file is an input, so editing one rebuilds Core. |

## Core modules

| Folder | Contents |
|---|---|
| `Scanner/` | `Scanner` (parallel `getattrlistbulk` traversal), `DirNode` tree, `ScanTree` in-place updates (`TreeMutations`), `HardLinkTable` in `HardLinks.swift` (every multiply-linked file, indexed by the folders holding its links, so an update touches only the files linked from where it changes the tree), `VolumeTable` (mounts, APFS containers, firmlinks). |
| `Layout/` | Squarified treemap and sunburst layouts, with hit testing. Pure geometry, shared by the app's Canvas and the TUI. |
| `Rules/` | `Rule` schema, `BuiltinRules` (the compiled-in rule files; a debug build's `SPACEKIT_RULES_DIR`), `RuleLibrary` (loading, validation, and overrides of built-in rules that may only narrow them), `RuleEngine` (matching rules against a tree). |
| `Intelligence/` | `StorageAnalyzer` (targeted scans + evaluation), `CategoryBreakdown`, `AIInspector`, `RuleIndex`, incremental updates, and `Workspace` (the app's and the TUI's Explore tree with its analysis, and the only place that changes the tree after a scan). |
| `Safety/` | `SafetyGuard`, the single gate for removals, and `RuleScope` (where a rule applies, shared by the guard, `RuleIndex` and `RuleEngine` so they agree). See [SAFETY.md](SAFETY.md). |
| `Cleanup/` | `CleanupPlan`, `CleanupReview` (the guard's verdict per row, unticked rows, totals and Trash wording; the only maker of a `ReviewedPlan`), `CleanupExecutor` (re-checks, removes, runs tool commands through the `ProcessRunner` port, journals each removal, and accounts for items deleted only in part; `SystemProcessRunner` runs real processes, tests stand in a recorder), `RemovalTarget` (one item's location, pinned identity, repository flags and size, read once for the guard and the removal), `Remover` (the Trash-or-delete decision, and the move or deletion checked against the target), `SafeRemoval` (deletion through checked directory handles, never by path: one folder open at a time, no recursion, carrying on past entries it can't remove, staying on the item's volume), `CommandTrust` (whether a tool command may run: rule origin, manual or automatic run, trusted list, `allowedCommands`, code launchers, option-like names, the warning every command of a user rule carries, changeable programs kept out of automatic runs, the real file a name leads to and a script's interpreter, and a local Docker context and buildx builder), `Journal`. |
| `Automation/` | `Job` and `Schedule`, `JobRunner` (evaluate, observe/suggest/clean, due logic), `ManualJobRun` (a job run by hand or a suggestion approved: prepare, then complete with the reviewed plan), `LaunchAgent`, state stores, notifications. |
| `Config/` | `SpaceKitConfig` (strict YAML decoding: a value it can't read makes the file invalid), `ConfigStore`, `SpaceKitContext` (one reading of the config: config, rule library, guard and executor, and the config error that stops cleaning; config changes return a new context). |
| `History/` | Usage samples and snapshots; "this month" and "what grew". |
| `Support/` | Shared plumbing: `PathUtil` (expansion, comparison keys), `FileTrust` (whether a config or rule file is safe to read, given who can change it), `Shell` (bare-name lookup, no-shell runs with timeouts), `ProcessRunner` (the port tool commands run through), `SpaceKitPaths`, ages and byte counts, JSON Lines. Also the terminal helpers both terminal front ends use, kept free of terminal I/O so they can be tested: `TerminalText` (the sanitizer), `TerminalWidth` (column widths), `KeyParser` (raw key bytes to keys), `ScrollWindow` and `Spinner`. |

## The scanner

The scanner is the hot path. Its job is to turn millions of directory entries into a tree with sizes, as fast as the disk allows, without running out of memory.

- **`getattrlistbulk(2)`** returns names, types, sizes and dates for many entries per system call, about 3–5× fewer syscalls than `readdir` + `stat`, and far faster than `FileManager` enumeration.
- **Parallel work-stealing.** Worker threads share a LIFO stack of directories. Each worker keeps one child for itself and shares the rest, so the stack stays shallow and lock traffic low. Directory listing on APFS is bound by kernel locks rather than CPU. Measured on an M-series Mac (185k folders): 1 thread 5.8s, 4 threads 2.7s, 6 threads 2.7s, 24 threads 5.4s. Hence the default of about 6 threads (`scan.threads`). A 207 GB home folder with 1.8M files scans in about 13s (release build).
- **Compact memory.** Folders are objects; files are kept individually only when at least `scan.minFileSize` (1 MB by default). Smaller files are folded into per-folder totals. Swift `String`s are created only for folders and tracked files. Marker files (`package.json`, `Cargo.toml`, `.git`, …) are recognised by comparing raw bytes and stored as a 64-bit mask per folder, which is what lets pattern rules work without keeping every file name.
- **Correct sizes.** Allocated bytes (what the disk spends, not logical length); hard links counted once (pnpm stores, Time Machine); symlinks never followed; autofs triggers never opened.
- **Hard links are attributed deterministically.** While the scan runs, a multiply-linked file's bytes go to the first link a worker reaches, so live totals stay right. When the workers finish, the bytes move to the link in the folder whose path sorts first (then by file name), so the same disk always gives the same tree whatever the thread timing. The other links stay in their folders' file counts with no bytes. The tree keeps each multiply-linked file's group of links after the scan, so later updates know where the bytes go.
- **The whole disk, once.** Scanning `/` crosses into every volume of the startup disk's APFS container (System, Data, VM swap, Preboot, Update) and skips data-volume paths that are also reachable through firmlinks (`/Users` ≡ `/System/Volumes/Data/Users`), using `/usr/share/firmlinks`. Other disks and virtual file systems are skipped. What the scan can't see is reported as *Hidden & Purgeable* (`used − scanned`).
- **Progressive results.** Folders down to `liveDepth` keep an atomic running total, and each folder is published (`isListed`, release/acquire) as soon as it's listed, so the app and TUI draw the map while the scan runs.
- **After the scan**, one non-recursive bottom-up pass computes totals, newest dates and subtree markers, and sorts children by size. After that the tree changes only through `applyRemoval`, `applyMove`, `applyArrival`, `splice` and `rescan`, which update every ancestor so views stay correct without rescanning.

### Who may touch a `DirNode`

`DirNode` is a class marked `@unchecked Sendable`. That rests on who writes when, not on immutability:

1. **During a scan**, the worker that lists a folder writes its fields, then publishes it (`isListed`, release/acquire). Other threads may read only `name`, `isListed` and `liveSize`, of the nodes in `ScanProgress.liveChildren`.
2. **When the workers finish**, the scanning thread resolves hard links and aggregates totals, sorting `children` in place, before `Scanner.scan` returns.
3. **After that**, only the tree's owner changes it, through `applyRemoval`, `applyMove`, `applyArrival`, `splice` and `rescan`, from one thread or actor at a time. Reads on other threads must be synchronized with those changes by the owner.

In the app and the TUI the owner is a `Workspace`, a `Sendable` class with a reader/writer gate on a `Mutex`. The rule: the front end's own thread reads the tree directly, because changes run only there; every other thread reads it only during a read the workspace counts.

- Changes run in steps the front end runs on its own thread (`Workspace.Deliver`): the app hands them to the main actor in order, the TUI to its main loop through its inbox. So SwiftUI views and the TUI's renderer read the tree directly, without a read.
- Background work reads the tree only inside `Workspace.read`, or during a read lease (`Workspace.beginRead()`, ended with `ReadLease.end()`): the analysis that reuses the tree (and records the History snapshot from it), and the app's map layout. A read waits only while a change is being applied.
- Work handed nodes the front end holds begins its read on the front end's thread, before it is handed over: the map layout takes a lease on the main actor and its detached task ends it. A change could otherwise land between the hand-over and the first read and free the nodes (or their parents) the work is about to walk.
- A change (a cleanup's removals, the Trash re-synced) is queued while any reader is left and applied when the last one ends, holding the gate so no new reader starts meanwhile.
- An analysis's result is put in place at the moment it stops reading, so a cleanup that finished while it ran is applied to the new findings rather than lost under them. An analysis replaced by a newer scan or analysis records no History snapshot.
- Showing a new scan (`Workspace.show`) drops the previous tree's analysis and the changes still queued for it: they were worked out on that tree. A cleanup that finished after the new scan started is applied to it again, since the scan may have counted an item before it went, whether the cleanup was applied to the previous tree, still waited for it, or came while no tree was shown. Only what the new tree still shows where it was is removed (`Removal.carried(over:)`). `show` does this at once, on the front end's thread, before anything reads the new tree, so an analysis started right after it (and its History snapshot) never counts what the cleanup removed. Whether the scan saw what the cleanup moved into the Trash can't be told (it may have walked the Trash before the move, or counted a small file only in the Trash's total), so instead of guessing, the workspace scans that Trash again and re-syncs it (`resync`). Cleanups that finished before the scan started are forgotten: the scan shows them already.

One-shot CLI commands own their trees outright and call `Scanner` and `StorageAnalyzer` directly.

### "Last used"

Modification time is used. Access times are recorded but are unreliable for folders: Spotlight and backup tools read files in the background, so an untouched folder can look used minutes ago. The exceptions are deliberate:

- For **project artifacts** (`node_modules`, `target/`), "last used" is the project's activity, meaning the newest change in the project outside the artifact, because package managers reset dates inside them.
- For **AI model weights**, reads do mean use, so the AI view uses access times.

## Rules and analysis

`RuleEngine.evaluate(tree)` produces `Finding`s:

1. **Fixed-path rules** expand `~` and globs, then look the paths up in the tree. `granularity: children` turns each entry (plus the folder's loose files) into an item.
2. **Pattern rules** walk the tree from their search roots. A folder matches by name plus a marker check: `sibling` in the parent's mask, `contains` in its own. Matching never descends into a match, into bundles, or into tool homes such as `~/Library` or `~/.cargo`. A worktree rule (`match.worktrees`) matches a folder by what it is instead of its name: a folder with the `.git` marker but no `.git` folder has its `.git` file read (`GitWorktree`), and an orphaned or idle worktree is matched. Its *last used* also counts git's record of the worktree in the repository.
3. **Overlaps are resolved** so no byte is counted twice. The more specific rule wins an exact path. An outer item that contains another rule's item is split into its children around it.

`StorageAnalyzer` decides what to scan. If the Explore tree already covers every location the selected rules need, it's reused. Otherwise only the needed roots are scanned, in one parallel multi-root pass. A job for DerivedData scans DerivedData, not your disk. Every rule of the library is still evaluated on what was scanned, in library order (a job's own folders last), and only the selected rules' findings are kept, so each selected rule gets exactly what a full analysis would give it.

## Incremental updates (no full refresh)

After a cleanup, the app and the TUI do **not** re-scan or re-analyse:

| What changed | What updates |
|---|---|
| Items removed from disk | `ScanTree.applyRemoval` shrinks the Explore tree (and the analysis tree, if separate) in place. Small files, which the tree only knows as a per-folder total, are removed using the size the executor measured. For loose files ("Files in …"), the folder is read again, because the executor may have skipped some of them. Removing the link that holds a hard-linked file's bytes hands them to the surviving link a rescan would credit. |
| Items deleted only in part | The report's `partiallyFreed` lists them, and so does `leftOnOtherVolumes` for items removed around a volume mounted inside them. `Removal.from` turns each into a partial removal. `ScanTree.rescan` scans the folder again with the tree's own options and splices it in, so the tree shows what's left. |
| Items moved to the Trash | `ScanTree.applyMove` re-attaches them under `~/.Trash`, so totals stay true: trashed data still uses the disk. Loose files moved to the Trash reappear under the Trash node where each one landed (the report's `trashedLooseFiles`). Afterwards the app re-scans the Trash and splices it in (`ScanTree.splice`), which also picks up a Trash emptied in Finder whenever SpaceKit becomes active. |
| Findings | `Analysis.apply(_:)` drops removed items, shrinks items that lost something inside or were deleted in part, and removes empty findings. Only the cards for touched rules change. |
| Tool commands (`brew cleanup`, `docker builder prune`) | Only those rules are re-evaluated, with a targeted scan of their own locations (`CleanupReport.rulesToReevaluate`). The card shows a small spinner meanwhile (`Workspace.State.refreshingRules`). |
| AI report | Rebuilt only if an AI rule was touched. Partial re-scans are merged into the existing report (`AIReport.replacingModels`), so other tools keep their models. |
| Category totals | Removed bytes are subtracted from their category, with no tree walk. |
| Disk map | Re-laid out only if the Explore tree changed (`treeRevision`). |
| Automation screen | The journal and job state are re-read (cheap). launchd is only queried when the Automation screen appears. |

Both front ends hand the report to their `Workspace` (`apply(_:context:)`), which does all of the above to the tree and the findings, re-evaluates the rules whose tool command ran, and re-syncs the Trash when the app asks (`resync`). If a cleanup finishes while an analysis is reading the tree, its removals wait and are applied to that analysis's result when it ends. A rule re-evaluated again before the first re-evaluation ends belongs to the newer one: the older one neither stops its spinner nor merges its findings. A Trash scan is spliced only into the trees shown when it began (`resync(_:at:over:context:reevaluating:)` takes that workspace state), never into a tree shown or analysed since. Each change is announced once (`Workspace.Event.changed`) with what was removed and which folders were rescanned. The front end then fixes its own view: `Change.survivor(of:)` gives the folder to show in place of one that went (the nearest folder above where it was, also for items moved to the Trash), and `Change.isGone(_:)` says whether a selected path went. The change keeps the removed nodes alive until the front end has let go of it, because a `DirNode` doesn't keep its parent alive.

Config edits work the same way. A `SpaceKitContext` never changes: its config, the rule library loaded for it, and the guard and executor built from both once. Changing a job, a safety setting or the UI options goes through `SpaceKitContext.applying(_:)`, which applies that one change to the YAML file as it is on disk (`ConfigStore.update`, under the lock) and returns a new context that the app, the TUI or the CLI puts in place of its own. Whether the file is valid is decided then, from the file as it is now: a file fixed since it was loaded is adopted, one that is invalid now is refused with its problem and never overwritten. The rule library is reloaded only when rule settings (`rules.disabled`, `rules.directories`) change. The app also re-reads the file whenever it becomes active (`rereadingConfig()`), so edits made in an editor or with the CLI show up; there is no file watching. The guard keeps the mount table read when the context was built, and the executor reads it again at the start of each run.

Render-time work is cached too. Each folder's sorted item list and each path's rule lookup are memoised (outside observation) and invalidated by tree or rule changes. Disk-map layout and colors are computed off the main thread with a per-pass memo of rule lookups, so hovering and selecting only repaint.

### Proving it

`ScanTree.inconsistencies()` checks every folder's invariants (its files add up to its direct total, and its total equals direct files plus children). [`TreeConsistencyTests`](../Tests/SpaceKitCoreTests/TreeConsistencyTests.swift) runs randomized sequences of deletions, loose-file removals and moves to a Trash folder, with large and small files and hard links across folders. After every step it compares every folder's size in the incrementally updated tree with a full rescan of the disk. [`WorkspaceTests`](../Tests/SpaceKitCoreTests/WorkspaceTests.swift) runs the front ends' order of events: a scan, an analysis held open while a cleanup lands, then the tree checked for consistency and the findings compared with a fresh scan and analysis. It also checks that long readers never see a cleanup half applied, that a read lease holds changes back until it ends, that each change is announced once, and where the view goes when its folder is removed or moved to the Trash. With analyses and re-evaluations held on semaphores, it checks the races between them: a new scan shown after a cleanup keeps every byte whichever finished first, a replaced analysis records no History, the older of two re-evaluations of a rule changes nothing the newer one owns, and an older Trash scan leaves a newer tree alone. [`TreeHardLinkIndexTests`](../Tests/SpaceKitCoreTests/TreeHardLinkIndexTests.swift) moves hard links, adds them back with arriving loose files or a splice, and then removes them, and checks that an update's cost doesn't grow with the number of hard-linked files elsewhere in the tree.

## Free space

macOS reports two numbers, and a cleanup can look like it did nothing if you show the wrong one:

| `VolumeCapacity` | Meaning |
|---|---|
| `freeNow` | Unallocated blocks right now. |
| `available` | `freeNow` plus purgeable space (local Time Machine snapshots, purgeable caches, evictable iCloud files). This is what Finder calls *Available*, and what SpaceKit shows. |
| `purgeable` | `available − freeNow`. Released automatically when space is needed. |
| `used` | `total − available` (Finder's *Used*). |

With local Time Machine snapshots on the disk, deleting files doesn't change `freeNow` at all: the snapshots still reference those blocks, so the space moves to `purgeable`, and `available` grows. SpaceKit refreshes capacity every 3 seconds and when it becomes active, explains the split in a popover, and shows the `tmutil thinlocalsnapshots` command for anyone who wants it released immediately. It never thins snapshots itself.

## Cleanup pipeline

```
Finding / selection ──► CleanupPlan (each item carries its scan start)
        │                    │
        │                    ▼
        │              CleanupReview: verdict per row · unticked rows · totals · Trash wording
        │              rendered by the app sheet · TUI dialog · CLI preview, which ask
        │                    │ one acknowledgement per plan (records the warnings shown per row and the executor)
        ▼                    ▼
JobRunner (automatic) ─► AutomaticPlan      ReviewedPlan
                              └───────┬───────┘
                                      ▼
   CleanupExecutor: for each item ─► RemovalTarget (resolved once: folder, pinned dev+inode, repositories, size)
                                         ─► Trash or delete ─► SafetyGuard (again; an unshown warning skips) ─► budget
                                         ─► Remover: identity checked ─► trashItem (manual) or move by handle (automatic) + check what moved │ delete via handles, same volume
                                         ─► journal entry
                    for each command ─► tool found where reviewed? ─► verdict: gates + CommandTrust (launcher behind it?
                                         automatic: changeable, settings, symlinked rule folders) ─► budget ─► local Docker?
                                         ─► ProcessRunner: no shell, cleaned environment ─► measure freed ─► charge budget ─► journal entry
                                      │
                                      ▼
                                   report ─► incremental UI update
```

A verdict keeps each reason with the decision it calls for on its own (`SafetyVerdict.entries`), and every review labels each reason by that decision. A blocked item can also carry a reason that alone would only need confirmation, and that reason isn't shown as a block.

## Automation

`spacekit agent install` writes a per-user LaunchAgent that runs `spacekit agent run` every `automation.checkEvery` (kept between 5 minutes and 24 hours), with the installing command's config and state paths in its environment. Each run:

1. records a cheap usage sample (at most every 6 hours);
2. finds due jobs (`schedule.nextRun(after: lastRun ?? firstSeen) <= now`, so missed runs catch up after sleep). If job state can't be saved, no job runs, because every wake-up would otherwise repeat the same jobs;
3. evaluates each job with a targeted scan, applies `when` conditions, and observes, suggests or cleans. Automatic runs hand the executor an automatic plan, which acknowledges nothing;
4. takes the weekly full snapshot for History.

A person running a job by hand, or approving a suggestion, goes through one Core module, `ManualJobRun`, in two steps. `prepare` evaluates the job now and says whether the run goes ahead or skips, and why; a suggestion's saved plan is narrowed to the items the fresh evaluation still offers, and each kept item takes its facts from that evaluation (the saved file only narrows them). A job below its size threshold skips unless the person forces it ("Run Anyway", `--force`); a suggestion is held back only when nothing in it is still eligible or the guard blocks everything left in it (an invalid config, which blocks every row until it's fixed, doesn't count), and approving it then (`settleWithNothingLeft`) runs nothing, records the job's run and dismisses it. Approval ignores the job's size threshold on purpose: the threshold held when the job made the suggestion, and approving is the person's explicit go-ahead for what it still offers. The prepared plan goes through the review like any other cleanup. `complete`, which exists only on a prepared run, runs the reviewed plan (only rows of the prepared plan) with the executor of the context current then, which must be the one the review was made with (a plan reviewed before a settings change runs nothing and records nothing), records the job's run so its schedule moves on, and settles the suggestion: dismissed when nothing eligible is left, otherwise kept, narrowed to what's left, with the problems the run hit. Settling reads the suggestion as stored now, under the store's lock, and keeps only rows still in it, so two approvals of one suggestion never bring back what the other one settled, and a suggestion dismissed or replaced meanwhile stays as it is (`SuggestionFate.gone`). The app, the TUI and the CLI only show the prepared run and ask.

```
ManualJobRun.prepare(job | suggestion) ─► skipReason? ─► forced() ─► plan ─► CleanupReview ─► ReviewedPlan
                                                                                                    │
ManualJobRun.complete ◄─────────────────────────────────────────────────────────────────────────────┘
        ├─► CleanupExecutor ─► report
        ├─► job state (lastRun, outcome)
        └─► suggestion: dismissed, or kept with what's left and its problems
```

Job state, suggestions and config edits are read-modify-write under a lock file (`FileLock`), so the agent, the CLI and the app don't overwrite each other's changes.

## Colors

The disk map and charts use a categorical palette, a status palette (safety, always with icon and label) and a one-hue ordinal ramp (age). They're validated for color-vision deficiency and contrast in light and dark mode. See `Sources/SpaceKitApp/Theme.swift`. Don't eyeball replacements; re-validate them.
