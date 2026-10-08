import Foundation

/// Who is asking to remove something, and under what terms.
public enum CleanupContext: Sendable {
    /// A person picked this in the app, the TUI or the CLI. Whether they acknowledged a warning is up to the review
    /// (`CleanupReview`), not the guard.
    case manual
    /// A scheduled job is running unattended.
    case automatic(AutomationContext)

    public var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }
}

public struct AutomationContext: Sendable {
    public var jobID: String
    /// The job explicitly opted in to cleaning 🟡 review items.
    public var allowReview: Bool
    /// Folders the user explicitly listed in the job (rather than rules).
    public var customPaths: [String]
    public var olderThan: Age?
    public var usesTrash: Bool

    public init(jobID: String, allowReview: Bool = false, customPaths: [String] = [], olderThan: Age? = nil, usesTrash: Bool = true) {
        self.jobID = jobID
        self.allowReview = allowReview
        self.customPaths = customPaths
        self.olderThan = olderThan
        self.usesTrash = usesTrash
    }
}

public struct SafetyVerdict: Sendable, Equatable {
    public enum Decision: Int, Sendable, Comparable {
        case allow, confirm, block
        public static func < (lhs: Decision, rhs: Decision) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One reason with the decision it calls for on its own, so a front end can label a confirm reason as a
    /// warning even when another reason blocks the item.
    public struct Entry: Sendable, Equatable {
        public var decision: Decision
        public var reason: String
    }

    /// The strongest decision of all entries (`allow` with none).
    public var decision: Decision
    public private(set) var entries: [Entry]

    public var reasons: [String] { entries.map(\.reason) }

    init(decision: Decision, reasons: [String]) {
        self.decision = decision
        entries = reasons.map { Entry(decision: decision, reason: $0) }
    }

    public static let allow = SafetyVerdict(decision: .allow, reasons: [])

    public var isBlocked: Bool { decision == .block }

    /// Adds `reason`. A reason raised again keeps the stronger of its decisions.
    mutating func raise(_ decision: Decision, _ reason: String) {
        if decision > self.decision { self.decision = decision }
        if let index = entries.firstIndex(where: { $0.reason == reason }) {
            entries[index].decision = max(entries[index].decision, decision)
        } else {
            entries.append(Entry(decision: decision, reason: reason))
        }
    }

    /// The stricter of two verdicts, with the reasons of both.
    func merging(_ other: SafetyVerdict) -> SafetyVerdict {
        var merged = self
        for entry in other.entries { merged.raise(entry.decision, entry.reason) }
        return merged
    }
}

/// The single gate every removal passes through, in every front end.
///
/// The built-in protections below are not configurable. The config can only *add* protected paths.
/// Every comparison against a protected list uses `PathUtil.comparisonKey`, because APFS treats differently
/// cased or normalized spellings as the same folder. See `docs/SAFETY.md` for the reasoning behind each rule.
public struct SafetyGuard: Sendable {
    public let home: String
    public let userProtectedPaths: [String]
    public let protectedRules: [Rule]
    /// The mount table the guard was built with; `mounted(_:)` swaps in a fresh one.
    public private(set) var volumes: VolumeTable
    public let isRunningAsRoot: Bool
    /// Where pattern rules without their own `roots` look (the config's `scan.devRoots`).
    public let patternRoots: [String]
    /// Reads the capacity of the volume holding a path. `capacities(readNowFor:)` swaps in one that keeps a run's readings.
    public private(set) var volumeCapacity: @Sendable (String) -> VolumeCapacity?

    /// `home` and, when it differs, where its symlinks lead: resolved once, for every list and every message.
    private let homes: [String]
    private let critical: [Location]
    private let sealed: [Location]
    private let personal: [Location]
    private let userProtected: [Location]
    private var mountKeys: [String]
    private let protectedPatterns: [ProtectedPattern]
    private let scope: RuleScope

    /// An automatic job may not remove a single item bigger than this share of the volume's used space.
    public static let maxAutomaticVolumeShare = 0.25
    /// A manual removal bigger than this share of used space needs confirmation.
    public static let confirmVolumeShare = 0.10

    public init(
        home: String = PathUtil.home, userProtectedPaths: [String] = [], protectedRules: [Rule] = [],
        volumes: VolumeTable = .current(), isRunningAsRoot: Bool = geteuid() == 0, patternRoots: [String] = ScanSettings.defaultDevRoots,
        volumeCapacity: @escaping @Sendable (String) -> VolumeCapacity? = { VolumeCapacity.of(path: $0) }
    ) {
        self.home = home
        self.userProtectedPaths = userProtectedPaths.map { PathUtil.expand($0, home: home) }
        self.protectedRules = protectedRules.filter { $0.safety.level == .protected }
        self.volumes = volumes
        self.isRunningAsRoot = isRunningAsRoot
        self.patternRoots = patternRoots
        self.volumeCapacity = volumeCapacity
        scope = RuleScope(home: home, patternRoots: patternRoots)
        // Resolved once, for every list: a home that is (or sits behind) a symlink is protected at its real location
        // too, whichever spelling an item arrives under.
        let homes = PathUtil.unique([home, PathUtil.realpath(home)].compactMap { $0 })
        self.homes = homes
        func locations(_ list: (String) -> [String]) -> [Location] {
            PathUtil.unique(homes.flatMap(list)).map(Location.init)
        }
        critical = locations(SafetyGuard.criticalPaths)
        sealed = locations(SafetyGuard.sealedTrees)
        personal = locations(SafetyGuard.personalAreas)
        // A protected path that is (or sits behind) a symlink is protected at its real location too.
        userProtected = userProtectedPaths.flatMap { written in
            homes.flatMap { home in
                let path = PathUtil.expand(written, home: home)
                return [path, PathUtil.resolveParent(path), PathUtil.realpath(path)].compactMap { $0 }
                    .map { Location(path: path, key: PathUtil.comparisonKey($0)) }
            }
        }
        mountKeys = SafetyGuard.mountKeys(volumes)
        protectedPatterns = self.protectedRules.map { rule in
            let patterns = rule.paths.flatMap { path in homes.map { PathUtil.comparisonKey(PathUtil.expand(path, home: $0)) } }
            return ProtectedPattern(
                rule: rule, patterns: PathUtil.unique(patterns), names: Set((rule.match?.names ?? []).map(PathUtil.comparisonKey)))
        }
    }

    /// This guard with another mount table; everything else it resolved when it was built stays as it is.
    func mounted(_ volumes: VolumeTable) -> SafetyGuard {
        var mounted = self
        mounted.volumes = volumes
        mounted.mountKeys = SafetyGuard.mountKeys(volumes)
        return mounted
    }

    private static func mountKeys(_ volumes: VolumeTable) -> [String] {
        volumes.volumes.map { PathUtil.comparisonKey($0.mountPoint) }
    }

    /// This guard with the capacity of every volume holding one of `paths` read once, now, and kept. A run judges each
    /// item's share of the disk against the disk as it was when the run started: removing one item shrinks the used
    /// space, which would otherwise make the next item a larger share than the review showed and skip it. A path on a
    /// volume none of `paths` is on is read when it's judged.
    func capacities(readNowFor paths: [String]) -> SafetyGuard {
        let read = volumeCapacity
        var readings: [dev_t: VolumeCapacity] = [:]
        for path in paths {
            guard let device = SafetyGuard.device(of: path), readings[device] == nil, let capacity = read(path) else { continue }
            readings[device] = capacity
        }
        var fixed = self
        fixed.volumeCapacity = { [readings] path in SafetyGuard.device(of: path).flatMap { readings[$0] } ?? read(path) }
        return fixed
    }

    /// The device holding `path`, symlinks followed like a capacity reading follows them.
    private static func device(of path: String) -> dev_t? {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_dev : nil
    }

    // MARK: Built-in lists

    /// Never removed, and nothing that *contains* them is ever removed either. This is what makes
    /// "delete the whole disk", "delete my home folder" or "delete /Users" impossible.
    static func criticalPaths(home h: String) -> [String] {
        [
            "/", "/System", "/System/Volumes", "/System/Volumes/Data", "/System/Volumes/Preboot", "/System/Volumes/VM",
            "/System/Volumes/Update", "/usr", "/bin", "/sbin", "/etc", "/var", "/tmp", "/private", "/private/etc",
            "/private/var", "/private/var/db", "/private/tmp", "/Library", "/Applications", "/Users", "/Volumes", "/opt", "/cores", "/dev",
            "/Library/Keychains", "/Library/Developer",
            h, "\(h)/Library", "\(h)/Library/Keychains", "\(h)/Library/Application Support", "\(h)/Library/Containers",
            "\(h)/Library/Group Containers", "\(h)/Library/Preferences", "\(h)/Library/Mobile Documents", "\(h)/Library/CloudStorage",
            "\(h)/Library/Mail", "\(h)/Library/Messages", "\(h)/Library/Caches", "\(h)/Library/Developer",
            "\(h)/Library/Application Support/AddressBook", "\(h)/Library/Calendars", "\(h)/Library/Photos",
            "\(h)/Documents", "\(h)/Desktop", "\(h)/Downloads", "\(h)/Pictures", "\(h)/Movies", "\(h)/Music", "\(h)/Public",
            "\(h)/Applications", "\(h)/Developer",
            "\(h)/.ssh", "\(h)/.gnupg", "\(h)/.aws", "\(h)/.kube", "\(h)/.config", "\(h)/.docker", "\(h)/.cache", "\(h)/.local",
            "\(h)/.Trash",
            "\(h)/Library/Containers/com.docker.docker/Data/vms",
        ]
    }

    /// Nothing inside these, nor the folders themselves, is ever removed: the OS, credentials, and app
    /// databases that break when edited.
    static func sealedTrees(home h: String) -> [String] {
        [
            "/System", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share", "/bin", "/sbin", "/private/etc",
            "/private/var/db", "/Library/Keychains", "/System/Volumes/Preboot", "/System/Volumes/VM", "/System/Volumes/Update",
            "\(h)/Library/Keychains", "\(h)/.ssh", "\(h)/.gnupg", "\(h)/.aws", "\(h)/.kube", "\(h)/.config/gcloud", "\(h)/.config/gh",
            "\(h)/Library/Mail", "\(h)/Library/Messages", "\(h)/Library/Application Support/AddressBook", "\(h)/Library/Calendars",
            "\(h)/Library/Group Containers/group.com.apple.calendar",
            "\(h)/Library/Containers/com.docker.docker/Data/vms", "\(h)/Library/Group Containers/group.com.docker",
            // Password managers: their vaults and local caches of them.
            "\(h)/Library/Application Support/1Password", "\(h)/Library/Group Containers/2BUA8C4S2C.com.1password",
            "\(h)/Library/Containers/com.1password.1password", "\(h)/Library/Group Containers/2BUA8C4S2C.com.agilebits",
            "\(h)/Library/Containers/com.agilebits.onepassword7", "\(h)/Library/Application Support/Bitwarden",
            "\(h)/Library/Containers/com.bitwarden.desktop", "\(h)/Library/Containers/in.sinew.Enpass-Desktop",
            "\(h)/Library/Application Support/KeePassXC", "\(h)/Library/Application Support/Proton Pass",
            "\(h)/Library/Containers/com.lastpass.LastPass",
        ]
    }

    /// Personal areas. A person may remove things inside them after confirming; automation only under strict terms.
    static func personalAreas(home h: String) -> [String] {
        [
            "\(h)/Documents", "\(h)/Desktop", "\(h)/Downloads", "\(h)/Pictures", "\(h)/Movies", "\(h)/Music",
            "\(h)/Library/Mobile Documents", "\(h)/Library/CloudStorage", "\(h)/Library/Containers", "\(h)/Library/Group Containers",
            "\(h)/Library/Application Support/MobileSync", "\(h)/Public",
        ]
    }

    /// Name suffixes of package folders whose insides must never be edited piecemeal. Lowercase, compared
    /// against comparison keys.
    static let sealedBundleSuffixes = [
        ".photoslibrary", ".photolibrary", ".musiclibrary", ".tvlibrary", ".aplibrary", ".keychain-db", ".keychain",
    ]

    // MARK: Evaluation

    /// Why `path` is refused for where it is, before anything is known about what's there; `nil` when its location
    /// alone refuses nothing. For checks ahead of the facts: `clean` before it measures a folder it may not need to,
    /// `jobs add` about whatever a job may find in a folder.
    ///
    /// The facts (size, git repositories) aren't judged here, and they can't be stood in for: each can only add a
    /// reason, so what this refuses is refused whatever is there, and `nil` permits nothing. The review and the
    /// removal judge the facts once they are known.
    public func locationRefusal(of path: String, rule: Rule?, context: CleanupContext) -> [String]? {
        // No size and no repository are the facts that add no reason; the verdict is the location's alone.
        let location = RemovalTarget.at(
            path, home: home, size: 0, isRepository: false, containsRepository: false, probingRepositories: false)
        let verdict = evaluate(location, rule: rule, context: context)
        return verdict.isBlocked ? verdict.entries.filter { $0.decision == .block }.map(\.reason) : nil
    }

    /// Decides whether `target` may be removed, from the facts it carries: its spellings, whether it is or contains a git
    /// working copy, and its size (for the volume-share checks). The guard reads no file itself; `RemovalTarget` read
    /// them, once, for the guard and the removal alike.
    ///
    /// - Parameter rule: the rule that produced the item, if any.
    public func evaluate(_ target: RemovalTarget, rule: Rule?, context: CleanupContext) -> SafetyVerdict {
        var verdict = SafetyVerdict.allow

        // Relative and `~name` paths stay unexpanded in the target.
        guard target.path.hasPrefix("/") else {
            return SafetyVerdict(decision: .block, reasons: ["Path must be absolute"])
        }
        let candidates = target.spellings

        if isRunningAsRoot {
            verdict.raise(.block, "SpaceKit never removes files while running as root (sudo)")
        }

        for candidate in candidates {
            checkHardLimits(candidate, into: &verdict)
        }
        if verdict.isBlocked { return verdict }

        if let rule, rule.safety.level == .protected {
            verdict.raise(.block, "\(rule.name) is marked “Don't touch”")
        }
        if target.isRepository {
            verdict.raise(context.isAutomatic ? .block : .confirm, "This folder is a git repository (source code)")
        } else if target.containsRepository && (rule == nil || rule!.safety.level != .safe) {
            verdict.raise(context.isAutomatic ? .block : .confirm, "This folder contains git repositories")
        }

        // Rule and job locations are resolved through symlinks, so scope is judged on resolved spellings (`/tmp/x` as
        // `/private/tmp/x`): where the parent's symlinks lead decides, not how the path was written.
        var scoped: [String] = []
        for candidate in candidates.map(PathUtil.resolveParent) where !scoped.contains(candidate) { scoped.append(candidate) }

        let isPersonal = candidates.contains { candidate in
            let key = PathUtil.comparisonKey(candidate)
            return personal.contains { PathUtil.isStrictAncestor($0.key, of: key) }
        }
        checkVolumeShare(target, context: context, into: &verdict)
        switch context {
        case .manual:
            checkManual(scoped, rule: rule, isPersonal: isPersonal, into: &verdict)
        case .automatic(let automation):
            checkAutomatic(scoped, rule: rule, isPersonal: isPersonal, automation: automation, into: &verdict)
        }
        return verdict
    }

    /// A single item holding a large share of its volume's used space needs confirmation, or in an automatic run past a
    /// larger share is blocked.
    private func checkVolumeShare(_ target: RemovalTarget, context: CleanupContext, into verdict: inout SafetyVerdict) {
        guard target.size > 0, let capacity = volumeCapacity(PathUtil.parent(target.path)), capacity.used > 0 else { return }
        let share = Double(target.size) / Double(capacity.used)
        if context.isAutomatic {
            if share > SafetyGuard.maxAutomaticVolumeShare {
                let percent = Int(share * 100)
                verdict.raise(.block, "Automatic cleanup won't remove a single item holding \(percent)% of the disk's used space")
            }
        } else if share > SafetyGuard.confirmVolumeShare {
            verdict.raise(.confirm, "This holds \(Int(share * 100))% of the disk's used space")
        }
    }

    /// A person's removal: what a rule doesn't vouch for needs confirmation. `scoped`: the item's spellings with their
    /// folders resolved.
    private func checkManual(_ scoped: [String], rule: Rule?, isPersonal: Bool, into verdict: inout SafetyVerdict) {
        // A rule speaks only for its own locations; elsewhere (a node_modules inside a tool's folder) the item is as
        // unknown as one no rule matched.
        if let rule, scoped.allSatisfy({ scope.contains($0, rule: rule) }) {
            if rule.safety.level == .review {
                verdict.raise(.confirm, "\(rule.name) is marked “Review”: it can be removed but may be slow or costly to get back")
            }
        } else if isPersonal {
            verdict.raise(.confirm, "This is personal data, not a cache")
        } else {
            verdict.raise(.confirm, "No SpaceKit rule recognises this; make sure you don't need it")
        }
    }

    /// An automatic run's removal: only what a rule covers, or a folder listed in the job, under strict terms.
    private func checkAutomatic(
        _ scoped: [String], rule: Rule?, isPersonal: Bool, automation: AutomationContext, into verdict: inout SafetyVerdict
    ) {
        let customRoots = automation.customPaths.map(scope.resolve)
        let isCustom = scoped.allSatisfy { candidate in customRoots.contains { PathUtil.isAncestorOrEqual($0, of: candidate) } }
        if let rule {
            if rule.safety.level == .review && !automation.allowReview {
                verdict.raise(.block, "\(rule.name) needs review; enable “Include review items” on the job to automate it")
            }
            if !scoped.allSatisfy({ scope.contains($0, rule: rule) }) {
                verdict.raise(.block, "Path is outside the locations rule \(rule.id) covers")
            }
        } else if !isCustom {
            verdict.raise(.block, "Automatic jobs only remove what a rule matched or a folder listed in the job")
        }
        // Rules carry curated knowledge about what's inside personal areas (Mail downloads, app caches in containers);
        // folders a person typed into a job don't, so those get the strict treatment.
        if isPersonal && rule == nil {
            let ageOK = (automation.olderThan?.days ?? 0) >= 7
            if !(isCustom && ageOK && automation.usesTrash) {
                verdict.raise(
                    .block,
                    "Automatic cleanup inside personal folders requires a folder listed in the job, "
                        + "“older than” of at least 7 days, and moving to Trash"
                )
            }
        }
    }

    /// Checks that can never be overridden.
    private func checkHardLimits(_ path: String, into verdict: inout SafetyVerdict) {
        let key = PathUtil.comparisonKey(path)
        let parts = PathUtil.components(key)
        if parts.count < 2 {
            verdict.raise(.block, "Top-level folders and volume roots can't be removed")
        }
        // /Volumes/<name> is where volumes mount; block it even when nothing is mounted right now.
        if (parts.count == 2 && parts[0] == "volumes") || (parts.count == 3 && parts[0] == "system" && parts[1] == "volumes") {
            verdict.raise(.block, "Volume roots can't be removed")
        }
        if let critical = critical.first(where: { PathUtil.isAncestorOrEqual(key, of: $0.key) }) {
            verdict.raise(
                .block,
                critical.key == key
                    ? "\(abbreviated(critical.path)) is a protected system or home location"
                    : "Removing this would also remove \(abbreviated(critical.path)), which is protected")
        }
        if let sealed = sealed.first(where: { PathUtil.isAncestorOrEqual($0.key, of: key) }) {
            verdict.raise(.block, "\(abbreviated(sealed.path)) and everything inside it are never removed")
        }
        if mountKeys.contains(key) || mountKeys.contains(where: { $0 != "/" && PathUtil.isStrictAncestor(key, of: $0) }) {
            verdict.raise(.block, "This is (or contains) a mounted volume")
        }
        for protected in userProtected
        where PathUtil.isAncestorOrEqual(protected.key, of: key) || PathUtil.isAncestorOrEqual(key, of: protected.key) {
            verdict.raise(.block, "Protected in your configuration: \(abbreviated(protected.path))")
        }
        if parts.contains(".git") {
            verdict.raise(.block, "Git metadata is never removed")
        }
        if parts.dropLast().contains(where: { component in SafetyGuard.sealedBundleSuffixes.contains { component.hasSuffix($0) } }) {
            verdict.raise(.block, "Files inside libraries such as Photos are managed by their app")
        }
        for protected in protectedPatterns {
            let located = protected.patterns.contains { PathUtil.isInside(key, pattern: $0) || PathUtil.couldContain(key, pattern: $0) }
            if located || parts.contains(where: { protected.names.contains(String($0)) }) {
                verdict.raise(.block, "Protected by rule “\(protected.rule.name)”")
            }
        }
    }

    /// `path` with either spelling of home shown as `~`.
    private func abbreviated(_ path: String) -> String {
        homes.lazy.map { PathUtil.abbreviate(path, home: $0) }.first { $0 != path } ?? path
    }
}

/// A protected location as written (for messages) and as compared.
private struct Location: Sendable {
    let path: String
    let key: String
}

extension Location {
    init(_ path: String) {
        self.init(path: path, key: PathUtil.comparisonKey(path))
    }
}

/// A protected rule's locations and names, as comparison keys.
private struct ProtectedPattern: Sendable {
    let rule: Rule
    let patterns: [String]
    let names: Set<String>
}
