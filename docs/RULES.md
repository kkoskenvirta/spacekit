# Storage Rules

A **storage rule** is a small YAML description of one kind of data on a Mac: where it lives, what it is, how risky it is to remove, and how to clean it. Rules are SpaceKit's knowledge base. The app, the TUI, the CLI and the automation engine all read the same rules.

Built-in rules are written in [`rules/`](../rules) and compiled into SpaceKit when it is built, so an installed SpaceKit reads no rule folder for them. Your own rules go in `~/.config/spacekit/rules/` (or any folder listed under `rules.directories` in your config). A rule in your folder with the same `id` as a built-in rule replaces it, but only to narrow it (see [Your own rules and overrides](#your-own-rules-and-overrides)).

```sh
spacekit rules list                 # everything SpaceKit knows about
spacekit rules show xcode.derived-data
spacekit rules validate my-rules.yaml
spacekit rules new --name "My cache" --path ~/Library/Caches/MyTool   # scaffold
```

## File layout

A rule file is either **a single rule**, or **a list of rules** with shared defaults:

```yaml
group: Xcode                 # display group for every rule in this file
category: developer.build    # default category

rules:
  - id: xcode.derived-data
    name: Xcode DerivedData
    # …
```

```yaml
# single-rule file
name: My tool cache
path: ~/Library/Caches/com.example.tool
safety: safe
action: remove
```

## Fields

| Field | Required | Description |
|---|---|---|
| `id` | recommended | Unique, stable, dotted: `<ecosystem>.<thing>`, e.g. `node.npm-cache`. Defaults to a slug of `name`. Jobs refer to rules by id. |
| `name` | yes | Short display name: `Xcode DerivedData`. |
| `group` | | Display group (`Xcode`, `JavaScript`, `Ollama`). Defaults to the file's `group`. |
| `category` | | Dotted category. The first part drives the app's breakdown: `developer.*`, `ai.*`, `cache.*`, `system.*`, `personal.*`. Rules made with `spacekit rules new`, and the folders a job lists itself, use `personal.custom`. |
| `description` | | One or two sentences, written for a developer: what it is, and what happens if it's removed. |
| `path` | one of `path`/`match` | Fixed location(s). String or list. `~` and globs (`*`, `?`, `[…]`) allowed. Must be at least two levels deep. Neither the path nor the folder its first glob sits in may be the home folder, a volume root or a top-level folder, so `~` and `~/*` are both rejected. |
| `match` | one of `path`/`match` | Name-based matching anywhere under search roots (see below). |
| `granularity` | | `whole` (default): the matched folder is one item. `children`: each entry inside is an item, so age rules apply per entry (per project in DerivedData). |
| `recreatedBy` | | What recreates it ("Xcode", "npm install"). Shown as *Recreated by*. |
| `safety` | | `safe`, `review` or `protected` (see below), or `{ level: safe, trash: false }`. Default `review`. |
| `policy` | | Suggested automation when someone creates a job from this rule (see below). |
| `exclusions` | | Globs to leave alone, plus the token `active_projects` (honour `policy.keepRecent`, default 14 days). |
| `action` | | How to clean (see below). Default: nothing (report only). |
| `ai` | | Marks AI storage for the AI Development view (see below). An unknown `layout` is a warning, and the storage is shown as a cache. |
| `docs` | | Link to the tool's own documentation on its storage. |
| `tags` | | Free-form labels. |

### Safety levels

| Level | Meaning | Automation |
|---|---|---|
| `safe` 🟢 | **Regenerable.** The owning tool recreates it on demand: build output, package caches, logs. | Allowed in `automatic` jobs. |
| `review` 🟡 | **Removable, but costs something**: re-download time (models, simulator runtimes), or it may be wanted (archives, backups). | Only with `includeReview: true` on the job; manual removal asks for confirmation. |
| `protected` 🔴 | **Don't touch.** Listed so SpaceKit can *show* it and *protect* it: source code, credentials, databases, Docker volumes, photo libraries. | Never. The safety guard blocks removal of these paths and anything containing them. Protected rules may not have an `action`, not even `manual` steps. |

Aliases are accepted: `regenerable`/`low` → `safe`; `caution`/`medium` → `review`; `never`/`keep`/`high` → `protected`. Any other word (such as `green` or `red`) is an error.

`safety.trash` (default `true`) says whether removal goes to the Trash. Set it to `false` only for data that is regenerated with no loss (build output, caches). Users can force the Trash for everything with `safety.trash: always` in their config, which is also the default.

### `match`: finding project artifacts anywhere

```yaml
match:
  names: [node_modules]        # folder names to match
  sibling: [package.json]      # at least one of these must exist next to the match
  contains: [pyvenv.cfg]       # at least one of these must exist inside the match
  roots: [~/Developer]         # where to search (default: the user's scan.devRoots, normally ~)
  exclude: [~/Work/vendor/**]  # extra globs never searched
```

Matching stops at the first match, so nested `node_modules` inside a matched one are part of it. SpaceKit never searches inside `~/Library`, tool homes (`~/.cargo`, `~/.npm`, `~/.vscode`, …) or bundles (`.app`, `.photoslibrary`), so an editor extension's `node_modules` is never mistaken for one of your projects. **Always use `sibling` or `contains`** when the folder name is generic (`build`, `target`, `dist`, `.venv`).

For project artifacts, *last used* is the project's activity (the newest change anywhere in the project except the artifact itself), because package managers reset file dates inside `node_modules` and friends.

To find unused git worktrees, whatever their folder names, write `worktrees` instead of `names`:

```yaml
match:
  worktrees:
    idleFor: 30d               # unused once nothing changed in it, and git recorded nothing for it, this long
```

A worktree is a folder whose `.git` is a file naming a folder in a repository's `.git/worktrees/`, as `git worktree add` leaves it. A submodule's `.git` file names `.git/modules/` instead, so submodules don't match. A worktree matches when it is orphaned or idle:

- **Orphaned:** the folder its `.git` file names is gone, because the repository was deleted or moved, or `git worktree prune` dropped it. Git can't use the worktree any more.
- **Idle:** nothing changed inside the worktree, and git recorded nothing for it, for `idleFor`. Git's record of a worktree is its index, `HEAD` and reflog in the repository, which commits and checkouts update.

A worktree in use doesn't match, so the search goes on into it, and its `node_modules` stays with its own rule. An unused worktree is one item with everything inside it, so a `node_modules` rule or job no longer counts or cleans the `node_modules` inside it. A worktree whose repository can't be reached, because its volume isn't mounted or a folder can't be read, isn't orphaned and doesn't match. `idleFor` is at least a day, and an override may raise it but not lower it. A worktree is a repository, so removing one always needs confirmation and automatic jobs never remove one.

### `action`

```yaml
action: remove                       # shorthand for { remove: true }
action: none                         # report only (the default)

action:
  remove: true                       # remove matched items (Trash or delete per safety.trash)

action:
  command: [docker, builder, prune, --force]   # run the tool's own cleanup instead

action:
  itemCommand: [rustup, toolchain, uninstall, "{name}"]   # once per item; {name} and {path} are substituted

action:
  manual: "Docker Desktop → Settings → Resources → Disk image size"
```

As a word, `action` accepts only `remove` and `none`. Other words such as `trash`, `delete`, `clean`, `manual` or `report` are errors: say `remove` and set `safety.trash`, or write `manual:` steps.

In an `itemCommand`, `{path}` is the item's absolute path and `{name}` is its last path component (the folder or file name, not the display name). With `granularity: children`, that is the name of each entry, such as a toolchain in `~/.rustup/toolchains`. A `{name}` that starts with `-` would reach the tool as an option, so that item's command is refused. Item commands never run for an item's loose files. The SafetyGuard checks each item an `itemCommand` names, just like an item SpaceKit would remove itself.

Prefer the tool's own cleanup command when it exists (Docker, simctl, Homebrew, pnpm). It knows about references and locks that deleting files doesn't.

Commands run **without a shell**, so shell syntax (`;`, `&&`, `|`, backticks, `$(`) is an error. The first word must be a **bare program name** such as `brew`: no `/`, no `..`, no `{name}`. SpaceKit finds it on `PATH` and the usual Homebrew, Cargo, Go, Bun, Docker and OrbStack locations.

Which programs may run depends on where the rule comes from:

- **Built-in rules** (the rules compiled into SpaceKit from `rules/`; in debug builds, the folder `$SPACEKIT_RULES_DIR` names takes their place) may run these without extra configuration: `brew docker xcrun npm pnpm yarn bun ollama go cargo pip pip3 uv conda mamba gem pod flutter dart gradle huggingface-cli hf mise rustup orb podman colima swift deno`.
- **Your own rules**, from any rule folder, run a command only if its program is listed in your `safety.allowedCommands`, including programs on the list above, only in a cleanup you start by hand, and each time only once you accept it in the review, which shows the whole command and the file its program was found at (`--yes` alone skips it; add `--accept-warnings`). Automatic jobs skip these commands. `spacekit rules validate` warns about each such command.
- **In automatic jobs**, any rule's command runs only when its program, and every folder and symlink on the way to it, can't be changed by you (`/usr/bin`, `/bin`, a root-owned `/usr/local/bin` entry). Homebrew and per-user tools are usually yours, so automatic jobs skip them; they run when you start the cleanup.
- **Shells, interpreters and launchers** (`sh`, `bash`, `python…`, `perl`, `node`, `osascript`, `swift`, `env`, `xargs`, `find`, `open`, `xcrun`, `git`, `make`, `rsync` and similar) can't be listed in `safety.allowedCommands`, and neither can a name that isn't plain ASCII, so a rule of your own that starts with one never runs. A tool you list is also refused when its real file has a launcher's name, or is a script a launcher runs (`#!/bin/sh`, `#!/usr/bin/env python3`). Name the tool itself instead. See [CONFIGURATION.md](CONFIGURATION.md#values) for the full list.

A command in a saved plan (a suggestion) runs only while its rule is still loaded and still has the same command; otherwise it is refused until the plan is refreshed.

Tools run with a cleaned environment: `PATH`, `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_*`, `TMPDIR`, `XDG_*`, Homebrew's settings (`HOMEBREW_*`, such as `HOMEBREW_CACHE`, `HOMEBREW_NO_CLEANUP_FORMULAE` and `HOMEBREW_CLEANUP_MAX_AGE_DAYS`) and the variables that move a tool's own cache (`CARGO_HOME`, `RUSTUP_HOME`, `GOPATH`, `GOMODCACHE`, `GOCACHE`, `npm_config_cache`, `NPM_CONFIG_CACHE`, `PNPM_HOME`, `YARN_CACHE_FOLDER`, `GRADLE_USER_HOME`, `OLLAMA_MODELS`). A kept name that contains `TOKEN`, `PASSWORD`, `PASSWD`, `SECRET`, `KEY`, `AUTH` or `CREDENTIAL` (such as `HOMEBREW_GITHUB_API_TOKEN`) is dropped. In an automatic job a tool keeps only `PATH` (without the search folders you can change), `USER`, `LOGNAME`, `LANG` and `LC_*`, and gets `HOME` and `TMPDIR` from the system (your home from the password database, your temporary folder as macOS names it), so a tool home or Homebrew setting you set in your shell applies when you start a cleanup, and an automatic job uses the tool's default locations. It also starts in `/` and gets variables that leave your own settings files behind (`DOCKER_CONFIG=/var/empty`, `GOENV=off`, `GOTOOLCHAIN=local`, `NPM_CONFIG_USERCONFIG` and `NPM_CONFIG_GLOBALCONFIG` set to `/dev/null`, `UV_NO_CONFIG=1`, `xcrun_nocache=1`); a built-in rule whose tool's settings can't be left behind that way runs by hand only (see [SAFETY.md](SAFETY.md#tool-settings-in-automatic-runs)). A new built-in rule's tool needs an entry in `CommandTrust.isolatedTools` or `CommandTrust.unisolatedTools` (a test fails until it has one; the test checks those lists, not the table) and a row in that table. Everything else, such as `DEVELOPER_DIR` (so `xcrun simctl` uses the Xcode `xcode-select` chose), `DOCKER_HOST`, `DOCKER_CONTEXT`, `BUILDX_BUILDER`, `OLLAMA_HOST` and tokens, stays behind. A `docker` command runs only when the active Docker context (`docker context inspect`) is a unix socket on this Mac, as with Docker Desktop, OrbStack and Colima. A `docker builder` or `docker buildx` command also needs the selected buildx builder (`docker buildx ls`, or `docker buildx inspect` for a buildx older than 0.13) to use the `docker` or `docker-container` driver with every node on such a socket, directly or through a context. Without the buildx plugin, `docker builder` uses the classic builder of the active context's daemon, so the context check is enough. A remote context or builder (`--driver remote`, Docker Build Cloud, Kubernetes), or an answer Docker can't give or SpaceKit can't read, skips the command with the reason. `DOCKER_HOST` in SpaceKit's own environment plays no part: the command never sees it.

### `policy`

Defaults for jobs created from the rule. The values are checked like the same values in a job: an unknown `type` or `mode`, a schedule SpaceKit doesn't understand, or an `olderThan` / `keepRecent` under a day is an error (see [CONFIGURATION.md](CONFIGURATION.md#values)).

```yaml
policy:
  type: size          # informational: size | age | schedule
  threshold: 30GB     # act when the total exceeds this
  olderThan: 60d      # only items unused this long
  keepRecent: 14d     # never items used within this window
  schedule: weekly    # hourly | daily | weekly | monthly | "sunday 03:00"
  mode: automatic     # observe | suggest | automatic
```

A job SpaceKit suggests for a rule whose action runs a `command` or `itemCommand` starts in `suggest` mode at most, whatever `mode` says: an automatic run starts a tool only from folders you can't change, which a typical install isn't (see [SAFETY.md](SAFETY.md#tool-settings-in-automatic-runs)), so such a job would skip every run. You approve the suggestion and it runs by hand. You can still set a job's mode to `automatic` yourself.

### `ai`

```yaml
ai:
  tool: Ollama         # name in the AI Development view
  layout: ollama       # how models are laid out on disk
  removeCommand: [ollama, rm, "{name}"]   # optional: how the tool removes one model
```

`removeCommand` is for tools whose models share files, so only the tool knows what may go. `{name}` is the model's name as the AI view shows it; `{path}` isn't allowed. It goes through the same checks as `action.command`: a bare executable name, built-in trust or `safety.allowedCommands` (manual runs only for your own rules), no `sudo`, confirmation for 🟡 rules and the automatic byte budget. Model names that start with `-` are refused. A model of a rule without `removeCommand` is removed by its folders.

| Layout | Meaning |
|---|---|
| `ollama` | Reads `manifests/` to size each model from its blobs, and finds unreferenced blobs. |
| `huggingface` | `hub/models--org--name` folders become `org/name` models and datasets. |
| `lmstudio` | `publisher/model` folders. |
| `children` | Each entry inside the path is one model. |
| `cache` | The whole thing is a cache (no per-model breakdown). |

## Writing a good rule

1. **Be precise about the path.** Point at the cache, not its parent. `~/Library/Caches/Homebrew`, not `~/Library/Caches`.
2. **Pick the honest safety level.** If removing it costs a 20 GB re-download, it's `review`, even if it's "just a cache".
3. **Say what happens** in `description`, for someone deciding in two seconds.
4. **Prefer tool commands** over file removal when the tool tracks what it stored.
5. **Validate:** `swift run spacekit rules validate` rebuilds SpaceKit with your edit and checks every built-in rule; `spacekit rules validate --builtin rules/your-file.yaml` checks one file as a built-in rule. Then try it: `spacekit dev --rule your.rule-id`. The test suite fails on any built-in rule that doesn't parse or has an error.
6. Built-in rules are reviewed for accuracy on current macOS and tool versions. Include a `docs` link if the tool documents its storage.

## Your own rules and overrides

Rules load from the built-in library first, then from each of your rule folders. A rule with the `id` of an earlier one replaces it. Jobs name rules by id, and jobs from 🟢 rules that remove files run automatically, so an override of a built-in rule may only **narrow** it. Copy the built-in rule into your folder (`spacekit rules show <id>`) and then:

- **You may** narrow its paths, add `exclusions` and pattern `exclude` globs, drop names from a pattern, raise `policy` `threshold`, `olderThan` and `keepRecent`, make its suggested `schedule` less frequent, raise the safety level, drop the action, and change the name, description, group, category, docs and tags. Making it `protected` is always allowed.
- **Narrowing a path** means each of your paths names only locations one of the built-in rule's paths names, at the same depth. Paths are compared where SpaceKit looks for them: `~` expanded, `.`, `..`, repeated and trailing `/` collapsed, symlinked folders resolved as a scan finds them, and without case, so `~/Library/Caches/Foo/` and `/Users/you/library/caches/foo` are the same path, and a path through a symlink that leads out of the built-in path is refused. Each segment must equal the built-in segment, be a name it matches, or extend a built-in `X*` to `X<more>*` (`AndroidStudio2023*` under `AndroidStudio*`). As when SpaceKit expands a glob, a name starting with `.` matches only a segment that writes the `.` out, so `*` doesn't cover `.keys`. A segment with `**` must stay as the built-in rule wrote it. A path below a built-in path is refused (`~/Library/Caches/Foo/sub` under `~/Library/Caches/Foo`), because the rule would then judge other items: `~/Library/Developer/Xcode/DerivedData/*` would keep or remove each build folder by its own age instead of each project's. So is a path a built-in exclusion names or lies inside (`~/Library/Application Support/JetBrains/Toolbox`). Symlinked folders can change after the rules load, so every analysis checks your paths again where it then looks: a path that now leads out of the built-in rule (a symlink pointed elsewhere) is left out of that analysis, with an error the agent's log shows.
- **You may not** add a path or a pattern, add names to a pattern or change its `sibling`, `contains` or `roots`, change the granularity, drop an exclusion, add `remove`, change a `command`, `itemCommand` or `ai` settings, turn off `safety.trash`, lower a policy value, make jobs from it start in a more automatic mode, or make them run more often (`policy.schedule` `hourly` where the built-in rule says `weekly`; a rule without one means `weekly`). Such an override is rejected with an error naming what it widens, and the built-in rule stays. Give a new rule its own id instead.
- A **built-in `protected` rule can't be replaced** at all, and an override **can't lower the safety level** (`review` → `safe`, for example). To stop using a built-in rule, add its id to `rules.disabled` instead.

The background agent's log (`spacekit agent run`) names every rule of yours a due job uses in place of a built-in one, and `spacekit doctor` counts them.

`rules.disabled` turns rules off, except `protected` rules: those stay active, with a warning.

**Rule files must be yours.** Rules decide what SpaceKit removes and which tools it runs, and the background agent reads them unattended. A rule file is loaded only if it is owned by you or root, isn't writable by group or others, and isn't in a folder that group or others can write to without the sticky bit. Access control lists count as well: a file is refused if an allow entry for anyone but its owner or root lets them write, append, delete, change its attributes or extended attributes, its owner or its permissions, and a folder if such an entry lets them add files or subfolders, delete entries, or change its owner or permissions. Any other rule file is reported as an error (`not loaded: …`) and none of its rules load. The same applies to the config file (see [CONFIGURATION.md](CONFIGURATION.md#invalid-config)) and to a debug build's `SPACEKIT_RULES_DIR`. The built-in rules themselves are compiled into SpaceKit, so no file owner or mode is involved. `spacekit rules new` and the app's *New Rule…* write rule files 0644, and create the rules folder 0755, whatever your umask, so they pass.

**Invalid rules are not loaded.** A rule with any error (no `path` or `match`, a path that is too broad, an action on a protected rule, a command that isn't a bare program name, shell syntax in a command) is reported and left out, so it neither cleans nor protects anything. A file with a value SpaceKit can't read, such as an unknown safety level or schedule, doesn't parse and loads none of its rules. Run `spacekit rules validate` without arguments to check every loaded rule, including whether your overrides were accepted, or give it files to check them the way loading them would (a file other users can change is reported as "not loaded", as loading skips it); it exits with status 1 when there are errors.

## Overlaps

Rules may overlap (a generic `~/.cache` rule and a specific `~/.cache/huggingface` rule). SpaceKit never counts a byte twice: the more specific rule claims its folder, and the generic rule's item is split around it.
