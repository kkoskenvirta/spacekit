# Glossary

## Config

**Context**: one consistent reading of the config file (`SpaceKitContext`): the config, the rule library loaded for it, and the guard and executor built from both once; it never changes, a front end replaces it with a new one. _Avoid_: settings, environment.

**Config change**: one edit applied to the config file as it is on disk at that moment (`SpaceKitContext.applying`), returning a new context; refused, and never saved over the file, while the file is invalid. _Avoid_: config save, settings update.

**Config re-read**: reading the config file as it is now into a new context without changing it (`SpaceKitContext.rereadingConfig`), which the app does when it becomes active. _Avoid_: reload (that also re-reads the rule files), file watching.

## Rules and command trust

**Built-in rule**: a rule compiled into SpaceKit from the repository's `rules/` folder (`BuiltinRules.embedded`), which may run the tools on the built-in trusted list without configuration; only a debug build's `SPACEKIT_RULES_DIR` replaces them. _Avoid_: default rule, system rule, bundled rule.

**User rule**: a rule loaded from a rule folder on disk (the user rules folder or `rules.directories`); its commands run only when listed in `safety.allowedCommands`, only in manual runs, and each time only once the person accepts the command's warning. _Avoid_: custom rule, third-party rule.

**Override**: a user rule with a built-in rule's id, loaded in its place; it may only narrow the built-in rule (paths at the built-in paths' depth that name only locations they name, outside their exclusions, added exclusions, higher thresholds, ages or safety level, a less frequent schedule), checked when the rules load and again whenever the engine resolves its paths. _Avoid_: replacement rule, customisation.

**Command trust**: the module (`CommandTrust`) that decides whether a rule's tool command runs, from the rule's origin, the kind of run and the executable policy. _Avoid_: command allowlist (only part of it).

**Executable policy**: which executables may run: the built-in trusted list (built-in rules only, and the one place code launchers such as `bun`, `deno`, `swift` and `xcrun` may run, since their names and commands are fixed in the binary), `safety.allowedCommands`, and the code launchers it may never grant; for a user rule's command a backstop behind the person's acknowledgement. _Avoid_: whitelist.

**Own-rule warning**: the warning every user rule's command carries in a manual run (`CommandTrust.ownRuleWarning`), naming all its arguments and the file its tool was found at; it is never allowed outright, so `--yes` alone doesn't run it. _Avoid_: command confirmation.

**Code launcher**: an executable that runs whatever code or program its arguments or configuration name (a shell, an interpreter, `env`, `xargs`, `find`, `open`, `xcrun`, `git`, `rsync`); `safety.allowedCommands` can't list one in any spelling, and a tool whose real file has a launcher's name, or is a script a launcher runs, is refused when it would start. _Avoid_: interpreter (too narrow), dangerous command.

**Plain tool name**: a `safety.allowedCommands` entry made only of ASCII letters, digits, `.`, `_`, `+` and `-`, so the file system's case and Unicode folding can't turn it into another program's name. _Avoid_: safe name, ASCII name.

**Tool environment**: the cleaned environment every tool command SpaceKit starts runs with (`Shell.toolEnvironment`): PATH, HOME, user, locale, TMPDIR, XDG, Homebrew's settings and the variables that move a tool's own cache, minus any name that marks a credential; in an automatic run only PATH (the search folders the person can't change), user and locale from the environment, HOME and TMPDIR from the system, plus the isolation variables (`Shell.RunKind`). The editor `spacekit config edit` opens is the one program that gets the person's whole environment. _Avoid_: sanitized env.

**Changeable program**: a tool whose file, or a folder or symlink on the way to it, the person owns, can write, or that is writable by its group or by everyone (sticky or not) or through an access control list entry for anyone but root, even when the person themselves can't write it (`CommandTrust.changeablePart`), such as anything in `~/.local/bin`, a Homebrew prefix they own or an app in the admin-writable `/Applications`, or a script whose `#!` interpreter is one; automatic runs don't start one. _Avoid_: user-writable tool, untrusted binary.

**Isolated tool**: a built-in rule's tool an automatic run may start, because the settings of the person's it reads are left behind (`Shell.isolationVariables`, `/` as its working folder) or decide nothing about what it deletes or runs (`CommandTrust.isolatedTools`); every other tool runs by hand only. _Avoid_: sandboxed tool, safe tool.

**Process runner**: the port the executor finds and runs tools through (`ProcessRunner`); `SystemProcessRunner` starts real processes, tests use a recording runner. _Avoid_: shell (tools never run in one).

**Local Docker endpoint**: a Docker context whose endpoint is a unix socket on this Mac (Docker Desktop, OrbStack, Colima); `docker` rule commands run only against one, and `docker builder` commands only when the selected buildx builder is a `docker` or `docker-container` builder on one, or no buildx plugin is installed, so the classic builder prunes that daemon. _Avoid_: local daemon.

**Unused worktree**: a linked git worktree (`GitWorktree`) that is orphaned, because the folder its `.git` file names is gone, or idle, because nothing changed in it and git recorded nothing for it for the rule's `match.worktrees.idleFor`; the only kind of worktree a worktree rule matches. _Avoid_: stale worktree, dead worktree.

## Runs

**Manual run**: a cleanup a person reviews and starts by hand from the app, the TUI or the CLI. _Avoid_: interactive run.

**Manual job run**: a job a person runs by hand, or a suggestion they approve, in two steps (`ManualJobRun`): prepare evaluates the job and says whether it goes ahead or skips and why; complete runs the reviewed plan with the executor current then, records the job's last run and settles the suggestion. _Avoid_: preview job, job approval.

**Forced run**: a manual job run a person starts although the job is below its size threshold ("Run Anyway", `--force`). _Avoid_: override, threshold bypass.

**Automatic run**: a cleanup the background agent starts for an automatic job, under the automation limits and with no person confirming. _Avoid_: background run, scheduled run.

## Scans and plans

**Scan start**: the moment a scan began (`ScanTree.scanStarted`, `Analysis.scanStarted`); each cleanup item carries the scan start of the scan it came from, and loose files or Trash entries changed after it are never removed. _Avoid_: plan creation time, scan time.

**Workspace**: the Explore tree a person looks at in the app or the TUI, with its analysis (`Workspace`); the only place that changes the tree after the scan, waiting for every reader first. _Avoid_: session, model, tree store.

**Reader**: background work, such as an analysis or the map layout, that reads the workspace's tree inside `Workspace.read` or during a read lease; changes wait until none is left, and the front end's own thread, where changes run, is never one. _Avoid_: lock holder.

**Read lease**: a read of the workspace's tree that the front end's thread begins and the background work it hands nodes to ends (`Workspace.beginRead`, `ReadLease`), so no change can land in between. _Avoid_: lock, token.

**Workspace state**: the tree, the analysis and the rules being re-evaluated as of one moment, as a front end shows them (`Workspace.State`); a Trash re-sync changes only the trees of the state from when its scan began. _Avoid_: snapshot on its own (that's a History snapshot or a Time Machine snapshot).

**Change**: one in-place update of the workspace's tree and findings, a cleanup's removals or a re-synced folder, announced once to the front end (`Workspace.Change`). _Avoid_: refresh (that's the targeted re-evaluation of a few rules), update.

**Pending change**: a change waiting in the workspace for its readers to finish (`Workspace.PendingChange`); applied, it becomes a change. _Avoid_: write, queued update.

**Survivor**: the folder a front end shows in place of one a change took away: the nearest folder above where it was that's still in the tree (`Change.survivor(of:)`). _Avoid_: fallback, parent.

## Review and execution

**Review**: a plan as a person sees it before anything is removed (`CleanupReview`): the guard's verdict on each row, the rows they untick, totals and where the items go. _Avoid_: preview (only the CLI's rendering of it), confirmation dialog.

**Warning**: a reason on a verdict that needs confirmation; it runs only if the person accepted it in the review. _Avoid_: caution, alert.

**Acknowledgement**: the person's one go-ahead for a whole review, accepting the warnings it showed or none of them. _Avoid_: confirmation (per item), approval (that's for suggestions).

**Reviewed plan**: what a review produces on acknowledgement (`ReviewedPlan`): the selected rows, the reasons shown for each, where each item was judged and which executor judged them; the executor's only input for a manual run, and only that executor runs it. _Avoid_: confirmed plan.

**Outdated review**: a reviewed plan handed to an executor other than the one its review was made with, because the settings changed in between; nothing runs, every row is skipped and the report is `reviewOutdated`. The app's sheet reviews the plan again in place; the TUI says "Nothing was removed: review it again" and the person starts the review again. _Avoid_: stale plan, expired review.

**Reviewed location**: where the review judged an item: its path with the folder's symlinks resolved, and the folder and the item by device and inode (`RemovalTarget.Location`); a reviewed row runs only while the item is still there. _Avoid_: checked path.

**Not accepted**: a reviewed row skipped because the person didn't accept the warnings the review showed for it (`--yes` without `--accept-warnings`); like a changed row, it counts as a problem. _Avoid_: needs confirmation (that's an automatic run's skip, where nobody was asked).

**Changed since review**: a reviewed row skipped because its check at removal time raised a reason the review didn't show (a new warning, a larger share of the disk, a block) or the item isn't at its reviewed location; it counts as a problem. _Avoid_: stale row, unreviewed warning.

**Skip kind**: why a row was left alone, as a value on its skipped outcome (`SkipKind`); reports decide by it, never by the reason's wording: changed since review and not accepted are problems, while refused, gone, not scanned and over budget are not. _Avoid_: skip prefix, skip reason (that's the text shown).

**Report note**: a line of a run's result for a file left on purpose inside a "Files in …" item that was otherwise cleaned, because the check at removal time refused it or it was past the budget (`CleanupReport.notes`); like a refused item, it isn't a problem. _Avoid_: warning (that is a problem).

**Run circumstances**: what blocks every row because of how SpaceKit runs, not because of the row: an invalid config, running as root (`CleanupExecutor.blocksEverything`); fixing them unblocks the rows, so they never count as a suggestion having nothing left. _Avoid_: global block.

**Disposal**: where a review's selected items end up: moved to the Trash, deleted, deleted from the Trash because they are already there, or moved to the Trash except for those already there, which are deleted (`CleanupReview.disposal`; `isPermanent` when anything is deleted for good); the removal module decides it and every front end shows the review's wording for it (`disposalSummary`). _Avoid_: removal method (that's one item's, `Remover.Method`), trash mode.

**Automatic plan**: the plan `JobRunner` hands the executor for an automatic run (`AutomaticPlan`); it acknowledges nothing. _Avoid_: scheduled plan.

## Removing

**Removal target**: one item as the guard and the removal see it, read from the disk once (`RemovalTarget`): its folder with every symlink resolved, the folder and the item pinned by device and inode, whether it is or contains a git repository, and its size. _Avoid_: checked path, checked directory.

**Location refusal**: why a path is refused for where it is alone, before its size and repositories are known (`SafetyGuard.locationRefusal`); facts can only add reasons, so it never permits anything. _Avoid_: pre-check verdict, unmeasured target.

**Remover**: the module that takes an item off its place (`Remover`): it builds the item's removal target, decides Trash or delete in one place, and moves or deletes the item only while it still matches its target. _Avoid_: deleter, safe removal (that's only its handle-level deletion, `SafeRemoval`).

**Move by handle**: how an automatic run moves an item to the Trash: the entry leaves the checked folder's handle straight into the home Trash's handle under a name not yet taken there (`renameatx_np`, `RENAME_EXCL`), so no path is resolved again; Finder's Put Back doesn't know it. _Avoid_: unattended trash, raw rename.

**Removal**: one item a cleanup took off its place, as the report and the trees record it (`Removal`), whether deleted or moved to the Trash. _Avoid_: deletion.

## Suggestions

**Suggestion**: a cleanup plan a `suggest` job prepared, waiting for a person to approve or dismiss it. _Avoid_: pending cleanup, proposal.

**Approval**: a manual job run of a suggestion that reviews and runs its plan, narrowed to what the job's conditions still allow and not held back by the job's size threshold, or dismisses it without a run when nothing is left (nothing still eligible, or everything left blocked), recording the job's last run either way. _Avoid_: acceptance (that's for warnings).

**Settling a suggestion**: what an approval does with it afterwards: dismiss it when nothing eligible is left, otherwise keep it narrowed to what's left with the problems the run hit. _Avoid_: cleanup of suggestions.
