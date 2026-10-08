import Foundation

/// Which tools an automatic run may start. The agent runs as the person, with Full Disk Access and nobody watching, so a
/// program any process of theirs could swap for its own (one in `~/.local/bin`, `~/go/bin`, or a Homebrew prefix they
/// own) runs only when they start it themselves. In an automatic run a tool runs only when neither its file nor any
/// folder or symlink on the way to it is theirs or writable by them: `/usr/bin`, `/bin`, a root-owned `/usr/local/bin`.
extension CommandTrust {
    /// How many symlinks the walk follows before it gives up, as the system does.
    static let symlinkLimit = 32

    /// Why the command `arguments`, whose tool is found at `executable`, doesn't start in an automatic run, or `nil` when
    /// it may: the file, and for a script every interpreter it starts, must be one nothing of the person's can change,
    /// and the tool's settings must be left behind (`settingsRefusal`). A `#!/usr/bin/env` line is followed on the PATH
    /// the run's tool gets: `searchPath` (where the runner looks) without the folders the person could change.
    /// `changeable` finds what the person could change on the way to a file (`changeablePart(of:)`; tests stand in their
    /// own), and `developerFolderLink` is xcrun's developer folder link.
    func automaticRefusal(
        _ arguments: [String], at executable: String?, context: CleanupContext, searchPath: [String],
        changeable: (String) -> String?, developerFolderLink: String = CommandTrust.developerFolderLink
    ) -> String? {
        guard context.isAutomatic, let executable else { return nil }
        let name = arguments.first ?? ""
        let folders = Shell.automaticSearchPath(searchPath, changeable: changeable)
        let locate = { (name: String) in Shell.which(name, in: folders) }
        let refusal = CommandTrust.programWalkRefusal(name, at: executable, locate: locate) { program in
            changeable(program.path).map {
                "\($0) can be replaced by any program of yours, so '\(program.name)' runs only when you start it"
            }
        }
        guard let refusal else {
            return CommandTrust.settingsRefusal(arguments, changeable: changeable, developerFolderLink: developerFolderLink)
                .map(TerminalText.sanitize)
        }
        return TerminalText.sanitize(refusal)
    }

    /// Why a command that names no item (a whole rule's, or a model's) doesn't start in an automatic run for where its
    /// rule's paths lead, or `nil`. The tool cleans those folders by its own lights, with no check of SpaceKit's on what
    /// it deletes, so a folder on the way that is a symlink (`~/Library/Caches/go-build` leading to `~/Documents`) would
    /// have it clean wherever the link leads. Every folder below `home` on the way to each path the rule names is
    /// checked: the part before the first wildcard, and each match of a pattern. A manual run is left to the person,
    /// who reviews the command.
    static func linkedPathRefusal(_ rule: Rule, home: String) -> String? {
        for declared in rule.paths {
            let expanded = PathUtil.expand(declared, home: home)
            guard PathUtil.isStrictAncestor(home, of: expanded) else { continue }
            let literal = PathUtil.components(expanded).prefix { !PathUtil.isGlob(String($0)) }
            let paths = ["/" + literal.joined(separator: "/")] + (PathUtil.isGlob(expanded) ? PathUtil.glob(declared, home: home) : [])
            for path in paths {
                guard let link = firstSymlink(on: path, below: home) else { continue }
                return TerminalText.sanitize(
                    "\(PathUtil.abbreviate(link, home: home)), on the way to a folder rule \(rule.id) cleans, is a symlink, so its "
                        + "command could clean wherever that leads; it runs only when you start it")
            }
        }
        return nil
    }

    /// The first folder or file below `home` on the way to `path` that is a symlink; `nil` when none is, up to the first
    /// part that isn't there.
    private static func firstSymlink(on path: String, below home: String) -> String? {
        guard PathUtil.isStrictAncestor(home, of: path) else { return nil }
        var current = home
        for component in PathUtil.components(String(path.dropFirst(home.count))) {
            current = PathUtil.join(current, String(component))
            var st = stat()
            guard lstat(current, &st) == 0 else { return nil }
            if st.st_mode & S_IFMT == S_IFLNK { return current }
        }
        return nil
    }

    /// The first file, folder or symlink on the way to `path` that the person could change (`isChangeable`), following
    /// every symlink to the file it leads to; `nil` when there is none. A part that can't be read counts as changeable,
    /// so a walk that can't be finished refuses the tool.
    public static func changeablePart(of path: String) -> String? {
        changeablePart(of: path) { part, st in isChangeable(part, st) }
    }

    /// `changeablePart(of:)` with `judge` deciding each part; tests stand in a judge to see which parts the walk visits.
    static func changeablePart(of path: String, judge: (String, stat) -> Bool) -> String? {
        var st = stat()
        guard path.hasPrefix("/"), lstat("/", &st) == 0, !judge("/", st) else { return "/" }
        // Components still to walk, the next one last. Every folder in `current` is a real folder that was checked, so a
        // `..` after it goes back to its parent.
        var pending = PathUtil.components(path).reversed().map(String.init)
        var current = "/"
        var followed = 0
        while let next = pending.popLast() {
            if next == "." { continue }
            if next == ".." {
                current = PathUtil.parent(current)
                continue
            }
            let part = PathUtil.join(current, next)
            guard lstat(part, &st) == 0, !judge(part, st) else { return part }
            guard st.st_mode & S_IFMT == S_IFLNK else {
                current = part
                continue
            }
            followed += 1
            guard followed <= symlinkLimit, let target = readLink(part) else { return part }
            if target.hasPrefix("/") { current = "/" }
            pending += PathUtil.components(target).reversed().map(String.init)
        }
        return nil
    }

    /// True when `user` (the person) could change `part`, whose `lstat` is `st`, or put another file in its place: they
    /// own it, or can write it. Writing is judged several ways, and any one of them is enough, so the answer fails closed:
    /// the system's access check for this process, write permission for the group or for everyone (whoever is in the
    /// group, and with the sticky bit too, which stops renames but not new programs), or an access control list entry that
    /// lets anyone but root write it. A symlink's own mode and list don't matter: nobody rewrites a symlink in place, and
    /// replacing it takes its folder, which the walk checks.
    static func isChangeable(_ part: String, _ st: stat, user: uid_t = getuid()) -> Bool {
        if st.st_uid == user || faccessat(AT_FDCWD, part, W_OK, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        let type = st.st_mode & S_IFMT
        guard type != S_IFLNK else { return false }
        if st.st_mode & (S_IWGRP | S_IWOTH) != 0 { return true }
        return FileTrust.aclAllowsOthers(part, type == S_IFDIR ? FileTrust.folderWrites : FileTrust.fileWrites, owner: 0)
    }

    private static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Which settings of the person's an automatic run's tool reads. Any program of theirs can write those files, so a tool
/// runs unattended only when SpaceKit leaves them behind for it (`Shell.isolationVariables`, and the root folder as its
/// working folder), or when it reads none that decide what it deletes or which code it runs. docs/SAFETY.md has the
/// table of what each tool reads and how.
extension CommandTrust {
    /// Built-in rules' tools an automatic run may start: their settings are left behind, or decide nothing that matters.
    static let isolatedTools: Set<String> = ["go", "npm", "deno", "uv", "docker", "xcrun", "rustup", "ollama"]

    /// Built-in rules' tools whose own settings, which no variable leaves behind, decide what they delete or which code
    /// they load: what they read. Automatic runs refuse them.
    static let unisolatedTools: [String: String] = [
        "brew": "reads settings of yours that decide what it keeps (~/.homebrew/brew.env) and runs formula code from taps "
            + "in folders you own",
        "pod": "loads settings and Ruby gems from your home folder (~/.cocoapods, ~/.gemrc, ~/.gem)",
        "pnpm": "reads the store folder it prunes from settings of yours (~/.npmrc, pnpm's rc file)",
        "bun": "reads the cache folder it removes from settings of yours (~/.bunfig.toml)",
        "conda": "reads the package folders it cleans from settings of yours (~/.condarc), and its Python loads code from "
            + "your home folder",
    ]

    /// The link `xcode-select` keeps to the developer folder xcrun starts tools from.
    static let developerFolderLink = "/var/db/xcode_select_link"

    /// Folders Docker's CLI loads plugins from besides `$DOCKER_CONFIG/cli-plugins` (docker/cli's system plugin folders).
    static let dockerPluginFolders = [
        "/usr/local/lib/docker/cli-plugins", "/usr/local/libexec/docker/cli-plugins", "/usr/lib/docker/cli-plugins",
        "/usr/libexec/docker/cli-plugins",
    ]

    /// Why the command `arguments` doesn't start in an automatic run for the settings and helpers its tool reads, or
    /// `nil`.
    static func settingsRefusal(
        _ arguments: [String], changeable: (String) -> String?, developerFolderLink: String = CommandTrust.developerFolderLink
    ) -> String? {
        let name = arguments.first ?? ""
        let byHand = "so '\(name)' runs only when you start it"
        if let reads = unisolatedTools[name] { return "'\(name)' \(reads); any program of yours can change those, \(byHand)" }
        guard isolatedTools.contains(name) else { return "SpaceKit hasn't checked which settings of yours '\(name)' reads, \(byHand)" }
        switch name {
        case "xcrun":
            let tool = arguments.count > 1 ? arguments[1] : ""
            return xcrunRefusal(tool, link: developerFolderLink, changeable: changeable).map { "\($0), \(byHand)" }
        case "docker":
            return dockerFoldersRefusal(changeable: changeable).map { "\($0), \(byHand)" }
        default:
            return nil
        }
    }

    /// Why `xcrun` wouldn't start `tool` from a developer folder nothing of the person's can change, or `nil`. xcrun
    /// looks for the tool in the folder `link` leads to, and for one that isn't there it searches the PATH, toolchains
    /// and SDKs, which SpaceKit doesn't follow: the Command Line Tools have no `simctl`, so a simulator command there
    /// would run whatever else xcrun finds.
    private static func xcrunRefusal(_ tool: String, link: String, changeable: (String) -> String?) -> String? {
        var st = stat()
        guard lstat(link, &st) == 0, let developer = PathUtil.realpath(link) else {
            return "xcrun starts developer tools from the folder xcode-select chose, and \(link) is missing, so none is chosen"
        }
        let tools = link + "/usr/bin"
        if let part = changeable(tools) {
            return "xcrun starts developer tools from \(tools), and \(part) can be replaced by any program of yours"
        }
        let path = PathUtil.join(tools, tool)
        guard Shell.isBareName(tool), stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            return "the developer folder \(developer) has no '\(tool)' (the Command Line Tools have no simulators), and xcrun "
                + "would look for it elsewhere"
        }
        return changeable(path).map { "xcrun would start \(path), and \($0) can be replaced by any program of yours" }
    }

    /// Why Docker's settings folder or plugin folders aren't fixed, or `nil`: the empty folder the run points
    /// `DOCKER_CONFIG` at must be empty and nobody's but root's, and each system plugin folder, with every plugin in it,
    /// one the person can't change. A plugin folder that isn't there must be one they can't create.
    static func dockerFoldersRefusal(changeable: (String) -> String?, pluginFolders: [String] = dockerPluginFolders) -> String? {
        let settings = Shell.emptyFolder
        let empty = (try? FileManager.default.contentsOfDirectory(atPath: settings))?.isEmpty == true
        if let part = changeable(settings) ?? (empty ? nil : settings) {
            return "docker reads its settings from the empty folder \(settings) in automatic runs, and \(part) isn't empty or "
                + "can be changed by any program of yours"
        }
        for folder in pluginFolders {
            var existing = folder
            var st = stat()
            while existing != "/" && lstat(existing, &st) != 0 { existing = PathUtil.parent(existing) }
            let plugins = existing == folder ? (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] : []
            for path in [existing] + plugins.map({ PathUtil.join(folder, $0) }) {
                if let part = changeable(path) {
                    return "docker loads plugins from \(folder), and \(part) can be changed by any program of yours"
                }
            }
        }
        return nil
    }
}
