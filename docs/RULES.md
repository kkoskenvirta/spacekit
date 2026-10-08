# Storage Rules

A **storage rule** is a small YAML description of one kind of data on a Mac: where it lives, what it is, how risky it is to remove, and how to clean it. Rules are SpaceKit's knowledge base. The app, the TUI, the CLI and the automation engine all read the same rules.

Built-in rules live in [`rules/`](../rules). Debug builds (`swift run`) read them from the source checkout. A release binary reads the copy shipped with it: `make install` puts them in `share/spacekit/rules` under the install prefix, and the app carries its own. A release binary built some other way (`swift build -c release`) needs `SPACEKIT_RULES_DIR` pointed at a rule folder, or a `rules` folder beside the binary. Your own rules go in `~/.config/spacekit/rules/` (or any folder listed under `rules.directories` in your config). A rule in your folder with the same `id` as a built-in rule replaces it, within limits (see [Your own rules and overrides](#your-own-rules-and-overrides)).

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

In an `itemCommand`, `{path}` is the item's absolute path and `{name}` is its last path component (the folder or file name, not the display name). With `granularity: children`, that is the name of each entry, such as a toolchain in `~/.rustup/toolchains`. Item commands never run for an item's loose files. The SafetyGuard checks each item an `itemCommand` names, just like an item SpaceKit would remove itself.

Prefer the tool's own cleanup command when it exists (Docker, simctl, Homebrew, pnpm). It knows about references and locks that deleting files doesn't.

Commands run **without a shell**, so shell syntax (`;`, `&&`, `|`, backticks, `$(`) is an error. The first word must be a **bare program name** such as `brew`: no `/`, no `..`, no `{name}`. SpaceKit finds it on `PATH` and the usual Homebrew, Cargo, Go, Bun, Docker and OrbStack locations.

Which programs may run depends on where the rule comes from:

- **Built-in rules** (SpaceKit's own `rules/` library, or the folder `$SPACEKIT_RULES_DIR` names) may run these without extra configuration: `brew docker xcrun npm pnpm yarn bun ollama go cargo pip pip3 uv conda mamba gem pod flutter dart gradle huggingface-cli hf mise rustup orb podman colima swift deno`.
- **Your own rules**, and rules from any folder other than the built-in library, run a command only if its program is listed in your `safety.allowedCommands`, including programs on the list above. `spacekit rules validate` warns about each such command.

A command in a saved plan (a suggestion) runs only while its rule is still loaded and still has the same command; otherwise it is refused until the plan is refreshed.

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

### `ai`

```yaml
ai:
  tool: Ollama         # name in the AI Development view
  layout: ollama       # how models are laid out on disk
  removeCommand: [ollama, rm, "{name}"]   # optional: how the tool removes one model
```

`removeCommand` is for tools whose models share files, so only the tool knows what may go. `{name}` is the model's name as the AI view shows it; `{path}` isn't allowed. It goes through the same checks as `action.command`: a bare executable name, built-in trust or `safety.allowedCommands`, no `sudo`, confirmation for 🟡 rules and the automatic byte budget. Model names that start with `-` are refused. A model of a rule without `removeCommand` is removed by its folders.

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
5. **Validate:** `spacekit rules validate rules/your-file.yaml`, then try it: `spacekit dev --rule your.rule-id`. A rule with errors is not loaded.
6. Built-in rules are reviewed for accuracy on current macOS and tool versions. Include a `docs` link if the tool documents its storage.

## Your own rules and overrides

Rules load from the built-in library first, then from each of your rule folders. A rule with the `id` of an earlier one replaces it, so you can customise a built-in rule by copying it into your folder, with two limits that protect what the built-in library protects:

- A **built-in `protected` rule can't be replaced.** A rule of yours with its id is rejected with an error and the built-in rule stays.
- A replacement **can't lower the safety level** of the built-in rule it replaces (`review` → `safe`, for example). It may raise it. To stop using a built-in rule, add its id to `rules.disabled` instead.

`rules.disabled` turns rules off, except `protected` rules: those stay active, with a warning.

**Rule files must be yours.** Rules decide what SpaceKit removes and which tools it runs, and the background agent reads them unattended. A rule file is loaded only if it is owned by you or root, isn't writable by group or others, and isn't in a folder that group or others can write to without the sticky bit. Access control lists count as well: a file is refused if an allow entry for anyone but its owner or root lets them write, append, delete, change its attributes or extended attributes, its owner or its permissions, and a folder if such an entry lets them add files or subfolders, delete entries, or change its owner or permissions. Any other rule file is reported as an error (`not loaded: …`) and none of its rules load. The same applies to the built-in library and the config file (see [CONFIGURATION.md](CONFIGURATION.md#invalid-config)), except that built-in rule files may also be owned by the account that owns the running SpaceKit program: whoever installed SpaceKit installed them with it. `spacekit rules new` and the app's *New Rule…* write rule files 0644, and create the rules folder 0755, whatever your umask, so they pass.

**Invalid rules are not loaded.** A rule with any error (no `path` or `match`, a path that is too broad, an action on a protected rule, a command that isn't a bare program name, shell syntax in a command) is reported and left out, so it neither cleans nor protects anything. A file with a value SpaceKit can't read, such as an unknown safety level or schedule, doesn't parse and loads none of its rules. Run `spacekit rules validate` without arguments to check every loaded rule, including whether your overrides were accepted; it exits with status 1 when there are errors.

## Overlaps

Rules may overlap (a generic `~/.cache` rule and a specific `~/.cache/huggingface` rule). SpaceKit never counts a byte twice: the more specific rule claims its folder, and the generic rule's item is split around it.
