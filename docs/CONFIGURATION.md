# Configuration

SpaceKit reads one YAML file, shared by the app, the TUI, the CLI and the background agent:

```
~/.config/spacekit/config.yaml        (or $XDG_CONFIG_HOME/spacekit/config.yaml, or $SPACEKIT_CONFIG)
```

You can edit it two ways, and they stay in sync:

- **By hand.** Keep it in your dotfiles; `spacekit config validate` checks it; `spacekit config edit` opens it in `$EDITOR` and validates on save.
- **In the app.** *SpaceKit → Settings…* edits the same file. Each change is applied to the file as it is on disk at that moment, so jobs you added with the CLI meanwhile are kept. When the app writes it, your previous version is kept as `config.yaml.bak`. (Comments are not preserved by UI edits.)

```sh
spacekit config init        # write a commented starter config
spacekit config show        # print the effective config, defaults filled in
spacekit config path        # where config, rules and state live
```

Every key is optional. **Sizes** accept `500MB`, `30GB`, `1.5TB` (decimal, like Finder) or `512MiB` (binary). **Ages** accept `14d`, `2w`, `3mo`, `1y`, `12h`, `30m`; a bare number means days. **Schedules** accept `hourly`, `daily`, `weekly`, `monthly`, `sunday 03:00`, `daily at 02:30`, or an object. Details and limits are [below](#values). A config SpaceKit can't read stops all cleaning until it's fixed (see [Invalid config](#invalid-config)).

## Full reference

```yaml
version: 1

scan:
  defaultPath: /            # what Explore scans first; / is the whole startup disk, hidden folders included
  minFileSize: 1MB          # smaller files are summarised per folder ("812 smaller files"); 0 keeps every file
  boundary: container       # container | device | unrestricted (see below)
  exclude: []               # paths or globs never descended into, e.g. [~/VMs, "**/node_modules/.cache"]
  threads: 6                # scanner workers; omit for the measured default
  devRoots: [~]             # where pattern rules (node_modules, target/, .venv …) search for projects

safety:
  trash: always             # always: everything goes to the Trash · rules: regenerable caches may be deleted directly
  maxBytesPerRun: 100GB     # an automatic run never removes more than this
  protectedPaths: []        # your own never-touch list, e.g. [~/Work/client-archive]; adds to the built-in list
  allowedCommands: []       # tools rule commands may run beyond the trusted list; the only ones your own rules may run

rules:
  disabled: []              # rule ids to ignore, e.g. [cache.user-caches]
  directories:              # your own rule files (see RULES.md)
    - ~/.config/spacekit/rules

automation:
  notifications: true       # observe and suggest runs; automatic runs always notify (see below)
  checkEvery: 1h            # how often the background agent checks for due jobs (5m to 24h)
  snapshot: sunday 04:00    # full storage snapshot for History; "never" to disable
  activeModelWindow: 90d    # AI models used within this window count as active

jobs:
  - id: xcode-derived-data  # optional; derived from name
    name: Xcode DerivedData
    enabled: true
    rules: [xcode.derived-data]
    paths: []               # your own folders (instead of, or in addition to, rules)
    granularity: children   # for paths: clean each entry inside (children) or the folder itself (whole)
    mode: automatic         # observe | suggest | automatic
    schedule: sunday 03:00
    when:
      sizeAbove: 30GB       # only act when the matched total exceeds this
      olderThan: 60d        # only items unused at least this long
      keepRecent: 14d       # never items used within this window
    action: trash           # trash | delete | rule (follow each rule's safety.trash); see "Trash or delete" below
    includeReview: false    # allow 🟡 review items in automatic runs

ui:
  visualization: sunburst   # sunburst | treemap
  colorBy: branch           # branch | category | safety | age
  mapDepth: 4               # rings / nesting levels (1–8)
```

### `scan.boundary`

| Value | Scanning `/` covers | Use when |
|---|---|---|
| `container` (default) | Every volume in the startup disk's APFS container: System, Data, swap (VM), Preboot, Update. Firmlinked folders are counted once. | You want the whole disk to add up. |
| `device` | Only the volume of the scanned path. | Scanning one volume of a multi-volume container. |
| `unrestricted` | Every mount (except virtual file systems). | Scanning a folder that has other disks mounted inside. |

Space the scan can't see (local Time Machine snapshots, purgeable space, folders blocked by privacy settings) shows up as **Hidden & Purgeable** in the category breakdown.

### Values

**Ages.** Units are `m` (minutes), `h` (hours), `d` (days), `w` (weeks), `mo` (months of 30 days) and `y` (years of 365 days); long forms such as `days` or `months` work too, and a bare number means days. `m` is minutes, so write `3mo` for three months. Negative or infinite values and anything over 100 years are rejected.

`olderThan` and `keepRecent` (in jobs and in rule policies, and the CLI's `--older-than` / `--keep-recent`) must be at least 1 day. A shorter value is almost always a typo for months, so `6m` is rejected with "did you mean 6mo (months)?".

**Schedules.** A schedule written as text must be understood word for word: one frequency (`hourly`, `daily`, `nightly`, `weekly`, `monthly`) and/or one weekday (`sunday` or `sun`), at most one time as `HH:mm` (`7:05` works too), and the filler words `at`, `on` and `every`. A weekday on its own means weekly. Without a time, jobs run at 03:00. `hourly` runs at the minute of its time, `:00` unless you give one. Anything else, such as `daily at 3am`, `weekly 25:00` or `monthly on the 15th`, makes the config invalid instead of falling back to a default.

```yaml
schedule: sunday 03:00                          # weekly
schedule: daily at 02:30
schedule: monthly                               # day 1 at 03:00
schedule: { every: monthly, day: 15, at: "02:00" }
schedule: { every: weekly, weekday: friday, at: "18:30" }
```

A monthly job runs on `day` 1 to 28 (default 1), so it runs every month; a larger day is an error. Monthly text schedules always run on day 1; use the object form for another day.

**`checkEvery`** is kept between 5 minutes and 24 hours: a shorter value is raised to 5m and a longer one lowered to 24h. `spacekit agent install --every` uses the same range and prints the interval it actually installed.

### Trash or delete

`safety.trash` decides whether anything may skip the Trash:

| `safety.trash` | Manual cleanups | Automatic jobs |
|---|---|---|
| `always` (default) | Everything goes to the Trash; the executor enforces this whatever a front end asks for. The CLI refuses `--permanent`, and the app's cleanup sheet has no delete option and its button says Move to Trash. Emptying the Trash still deletes, since that is the only way to remove what's in it. | Everything goes to the Trash, whatever the job's `action`. |
| `rules` | When every rule in a cleanup is 🟢 with `safety.trash: false`, its items are deleted; otherwise everything goes to the Trash. The CLI's `--permanent` and the app's toggle delete everything. Paths you name on the CLI send the whole cleanup to the Trash unless you pass `--permanent`. | `action: delete` deletes 🟢 items; `action: rule` follows each rule; `action: trash` trashes. Everything that isn't 🟢 goes to the Trash. |

Items already in the Trash can only be deleted. Automatic runs delete them only when a 🟢 rule covers them.

### Jobs and modes

| Mode | What a scheduled run does |
|---|---|
| `observe` | Notifies you when the matched total is above `when.sizeAbove`. Removes nothing. |
| `suggest` | Prepares a cleanup plan and notifies you. Approve it in the app (Automation → Waiting for your approval) or with `spacekit suggestions approve <id>`, which previews it; add `--yes` to run it. Approving evaluates the job again first and drops items that no longer meet its conditions. |
| `automatic` | Cleans within the safety limits: 🟢 items only unless `includeReview`, inside the rule's locations, under `maxBytesPerRun`. Anything it removes that isn't 🟢 goes to the Trash. Notifies you whenever it removed something or left something undone. |

**Notifications.** `automation.notifications: false` silences observe and suggest runs. Automatic runs notify whenever they removed something, or skipped or failed an item or tool command, whatever the setting, because nobody watched them run.

Jobs only run on schedule when the background agent is installed (`spacekit agent install`, or *Install Agent* in the app). It is a per-user launchd job (`~/Library/LaunchAgents/dev.spacekit.agent.plist`) that wakes every `checkEvery`, runs due jobs, records a usage sample for History, and takes the weekly snapshot. If your Mac was asleep at the scheduled time, the job runs at the next check. A job the agent sees for the first time runs at its next scheduled time.

The agent uses the config and state folder of the command that installed it: `spacekit agent install --config ~/dotfiles/spacekit.yaml` writes that path (and `SPACEKIT_STATE_DIR`, if set) into the plist's environment. After changing `checkEvery` by hand, run `spacekit agent install` again; the app's Settings reinstall the agent for you.

`spacekit jobs run <id>` previews what a job would do; `--yes` runs it now, confirming the warnings the preview showed; `--scheduled` runs it exactly as the agent would. Run Now in the app and `x` in the TUI evaluate the job first. When its conditions aren't met (`sizeAbove`, `olderThan`, …) nothing is cleaned: the check is recorded as a manual run and its result shown, as with `jobs run --yes`. Otherwise the cleanup is reviewed like any other, and the run is recorded against the job.

Approving a suggestion (`spacekit suggestions approve <id> --yes`, or in the app) evaluates its job again, cleans what still qualifies and records a manual run of the job, so the job's last run moves to now. The suggestion is removed only when the cleanup removed something without problems; otherwise it stays so you can try again or dismiss it.

### Invalid config

A value SpaceKit can't read makes the whole file invalid; it is never silently replaced by a default. `spacekit config validate` names the key and the problem (for example `jobs.[0].when.olderThan: '6m' means 6 minutes; did you mean 6mo (months)?`) and exits with status 1. It also reports jobs that name an unknown or disabled rule.

While the file is invalid, every command, the TUI and the app keep working for anything read-only, using the defaults and showing a warning. **Nothing is removed and no tool command runs** until the file is fixed, because the defaults lack your protected paths, allowed commands and disabled rules. The TUI's header and a banner above every section of the app say that cleaning is off until the file is fixed. Nothing saves over an invalid file: `spacekit jobs add/remove/enable/disable` exit with status 1, and the app's Settings and the TUI show the error, so your hand edits stay as they are. Valid files are changed in place: SpaceKit re-reads the file and applies only the one change, so edits made elsewhere in the meantime are kept.

**Symlinks.** A config path that is a symlink (dotfiles) is read through the link. A symlink whose target is missing or can't be read is a config error, not a missing config, so cleaning stops instead of running on the defaults. `spacekit config init` never replaces a symlink, even with `--force`, and saves (the app, `spacekit jobs`) write through the link to its target. The backup, `config.yaml.bak`, is a regular file holding the previous contents, not a copy of the link (which would show the new config once it's saved).

**Who can change it.** The background agent reads the config unattended, so SpaceKit reads it only if it is owned by you or root, isn't writable by group or others, and isn't in a folder that group or others can write to without the sticky bit. Access control lists count too. The file is refused ("can be changed by other users (its access control list allows it)") if an allow entry for anyone but its owner or root grants write, append, delete, write attributes, write extended attributes, change owner or change permissions. Its folder counts as one others can change if such an entry grants add file, add subfolder, delete child, change owner or change permissions. For a symlink, the target's owner, permissions and access control list count, and both the link's folder and the target's folder. A config that fails this is a config error. Rule files follow the same rules, and one that fails them isn't loaded (see [RULES.md](RULES.md#your-own-rules-and-overrides)).

**SpaceKit's own files pass.** Files SpaceKit creates (the config, its backup, lock files, state files, rule files from `spacekit rules new` or the app's *New Rule…*, and the agent's plist) are written 0644, and folders it creates 0755, whatever your umask. A file you made stricter stays that way: rewriting a 0600 config keeps it 0600, and its backup gets the same mode. Under a umask such as 002 the defaults would make them group-writable, and SpaceKit would refuse its own config.

## Files SpaceKit writes

| File | What |
|---|---|
| `~/.config/spacekit/config.yaml` | Your config (only written when you change settings in the app, add or change jobs with `spacekit jobs`, or run `config init`). |
| `~/.config/spacekit/config.yaml.bak` | Your previous config, kept whenever SpaceKit rewrites it. |
| `~/.config/spacekit/rules/*.yaml` | Your own rules. |
| `~/Library/Application Support/SpaceKit/journal.jsonl` | Every removal (the audit log). |
| `~/Library/Application Support/SpaceKit/history.jsonl` | Usage samples and snapshots for History. |
| `~/Library/Application Support/SpaceKit/jobs-state.json` | When each job last ran and what it found. |
| `~/Library/Application Support/SpaceKit/suggestions.json` | Plans waiting for approval. |
| `~/Library/Application Support/SpaceKit/logs/agent.log` | Background agent output. |
| `*.lock` next to the config, job state and suggestions | Let the app, the CLI and the agent update those files without overwriting each other. |

Override the state folder with `SPACEKIT_STATE_DIR`, and the built-in rule library with `SPACEKIT_RULES_DIR`. Rules in that folder count as built-in, including the trust to run the built-in list of tools (see [SAFETY.md](SAFETY.md#tool-commands)).

## Permissions

To scan everything, SpaceKit needs **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access): the app for the app, your terminal for the CLI and TUI, and `SpaceKit.app/Contents/Helpers/spacekit` (or your installed `spacekit`) for the background agent. Without it, macOS hides Mail, Messages, Safari and other apps' data; scans still work, and the hidden part is reported. `spacekit doctor` checks this.
