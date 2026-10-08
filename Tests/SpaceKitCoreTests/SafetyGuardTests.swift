import Foundation
import Testing

@testable import SpaceKitCore

/// The guarantees in docs/SAFETY.md. If one of these fails, do not ship.
@Suite("Safety guard")
struct SafetyGuardTests {
    let guardian = testGuard()
    let manual = CleanupContext.manual
    let automatic = CleanupContext.automatic(AutomationContext(jobID: "test"))

    @Test(
        "Never removes the disk, a volume, or a top-level folder",
        arguments: [
            "/", "/System", "/Users", "/Applications", "/Library", "/private", "/usr", "/opt", "/Volumes",
            "/System/Volumes/Data", "/Volumes/External",
        ])
    func wholeDiskAndTopLevel(path: String) {
        let verdict = guardian.check(path, context: manual)
        #expect(verdict.isBlocked, "\(path) must be blocked")
    }

    @Test(
        "Never removes the home folder or anything that contains protected locations",
        arguments: [
            "/Users/tester", "/Users/tester/Library", "/Users/tester/Documents", "/Users/tester/Desktop",
            "/Users/tester/Pictures", "/Users/tester/Library/Application Support", "/Users/tester/Library/Containers",
            "/Users/tester/.ssh", "/Users/tester/Library/Caches", "/Users/tester/Library/Developer",
        ])
    func homeAndProtectedContainers(path: String) {
        #expect(guardian.check(path, context: manual).isBlocked)
    }

    @Test(
        "Never removes anything inside sealed trees",
        arguments: [
            "/System/Library/Frameworks/AppKit.framework", "/usr/bin/ls", "/Users/tester/.ssh/id_ed25519",
            "/Users/tester/Library/Keychains/login.keychain-db", "/Users/tester/Library/Mail/V10",
            "/private/var/db/receipts", "/Users/tester/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
        ])
    func sealedTrees(path: String) {
        #expect(guardian.check(path, context: manual).isBlocked)
    }

    @Test("Tilde paths are expanded before checking")
    func tildeExpansion() {
        #expect(guardian.check("~", context: manual).isBlocked)
        #expect(guardian.check("~/", context: manual).isBlocked)
        #expect(guardian.check("~/Library/..", context: manual).isBlocked)
        #expect(guardian.check("/Users/tester/Projects/../Library", context: manual).isBlocked)
    }

    @Test("Relative paths are refused")
    func relativePaths() {
        #expect(guardian.check("Library", context: manual).isBlocked)
    }

    @Test("Git metadata and photo libraries are never edited")
    func gitAndLibraries() {
        #expect(guardian.check("/Users/tester/Projects/app/.git", context: manual).isBlocked)
        #expect(guardian.check("/Users/tester/Projects/app/.git/objects", context: manual).isBlocked)
        #expect(guardian.check("/Users/tester/Pictures/Photos Library.photoslibrary/originals/0", context: manual).isBlocked)
    }

    @Test("Repositories need confirmation by hand and are never removed automatically")
    func repositories() {
        let path = "/Users/tester/Projects/app"
        let byHand = guardian.check(path, context: .manual, isRepository: true)
        #expect(byHand.decision == .confirm)
        #expect(guardian.check(path, context: automatic, isRepository: true).isBlocked)
    }

    @Test("User-protected paths block the path, its contents and its ancestors")
    func userProtectedPaths() {
        let guardian = testGuard(protectedPaths: ["~/Work/archive"])
        #expect(guardian.check("/Users/tester/Work/archive", context: manual).isBlocked)
        #expect(guardian.check("/Users/tester/Work/archive/2020", context: manual).isBlocked)
        #expect(guardian.check("/Users/tester/Work", context: manual).isBlocked)
        #expect(!guardian.check("/Users/tester/Work/scratch", context: manual).isBlocked)
    }

    @Test("Protected rules block their locations")
    func protectedRules() {
        let rule = Rule(
            id: "db.postgres", name: "Postgres data", paths: ["~/Library/Application Support/Postgres"],
            safety: SafetySpec(level: .protected))
        let guardian = testGuard(rules: [rule])
        #expect(guardian.check("/Users/tester/Library/Application Support/Postgres/var-16", context: manual).isBlocked)
        #expect(guardian.check("/Users/tester/Library/Application Support/Postgres", rule: rule, context: manual).isBlocked)
    }

    @Test("Nothing is removed while running as root")
    func root() {
        let guardian = testGuard(root: true)
        #expect(guardian.check("/Users/tester/Library/Caches/com.example", context: manual).isBlocked)
    }

    @Test("Regenerable rule items are allowed, by hand and automatically")
    func safeRuleItems() {
        let rule = Rule(
            id: "xcode.derived-data", name: "DerivedData", paths: ["~/Library/Developer/Xcode/DerivedData"],
            granularity: .children, safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        let path = "/Users/tester/Library/Developer/Xcode/DerivedData/App-abc"
        #expect(guardian.check(path, rule: rule, context: .manual).decision == .allow)
        #expect(guardian.check(path, rule: rule, context: automatic).decision == .allow)
    }

    @Test("Automatic runs stay inside the rule's locations")
    func automaticScope() {
        let rule = Rule(
            id: "xcode.derived-data", name: "DerivedData", paths: ["~/Library/Developer/Xcode/DerivedData"],
            granularity: .children, safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        #expect(guardian.check("/Users/tester/Projects/app", rule: rule, context: automatic).isBlocked)
    }

    @Test("Review items need opt-in for automation")
    func reviewItems() {
        let rule = Rule(
            id: "xcode.archives", name: "Archives", paths: ["~/Library/Developer/Xcode/Archives"],
            granularity: .children, safety: SafetySpec(level: .review), action: ActionSpec(remove: true))
        let path = "/Users/tester/Library/Developer/Xcode/Archives/2024-01-01"
        #expect(guardian.check(path, rule: rule, context: automatic).isBlocked)
        let optedIn = CleanupContext.automatic(AutomationContext(jobID: "a", allowReview: true))
        #expect(guardian.check(path, rule: rule, context: optedIn).decision == .allow)
        #expect(guardian.check(path, rule: rule, context: .manual).decision == .confirm)
    }

    @Test("Automatic runs never remove unrecognised folders the job didn't list")
    func automaticUnknown() {
        #expect(guardian.check("/Users/tester/Projects/app/build", context: automatic).isBlocked)
    }

    @Test("Personal folders: by hand with confirmation; automatically only under strict terms")
    func personalAreas() {
        let file = "/Users/tester/Downloads/installer.dmg"
        #expect(guardian.check(file, context: .manual).decision == .confirm)
        #expect(guardian.check(file, context: automatic).isBlocked)

        let strict = CleanupContext.automatic(
            AutomationContext(jobID: "dl", customPaths: ["~/Downloads"], olderThan: .days(30), usesTrash: true))
        #expect(guardian.check(file, context: strict).decision == .allow)

        let noAge = CleanupContext.automatic(AutomationContext(jobID: "dl", customPaths: ["~/Downloads"], olderThan: nil, usesTrash: true))
        #expect(guardian.check(file, context: noAge).isBlocked)

        let noTrash = CleanupContext.automatic(
            AutomationContext(jobID: "dl", customPaths: ["~/Downloads"], olderThan: .days(30), usesTrash: false))
        #expect(guardian.check(file, context: noTrash).isBlocked)
    }

    @Test("Mount points are never removed")
    func mountPoints() {
        let volumes = VolumeTable(
            volumes: [
                MountedVolume(
                    mountPoint: "/Users/tester/Library/Developer/CoreDevice/DeviceFS", device: "devices", fileSystem: "devicefs",
                    deviceID: 99, isBrowsable: false)
            ], firmlinks: [])
        let guardian = SafetyGuard(home: "/Users/tester", volumes: volumes, isRunningAsRoot: false)
        #expect(guardian.check("/Users/tester/Library/Developer/CoreDevice/DeviceFS", context: manual).isBlocked)
        #expect(guardian.check("/Users/tester/Library/Developer/CoreDevice", context: manual).isBlocked)
    }

    @Test("Symlinked parents are resolved before checking")
    func symlinkedParents() throws {
        let tree = try TempTree()
        try tree.directory("real/.git")
        try FileManager.default.createSymbolicLink(atPath: tree.path("link"), withDestinationPath: tree.path("real/.git"))
        let guardian = SafetyGuard(home: tree.root, volumes: emptyVolumes, isRunningAsRoot: false)
        // Removing something through the link means removing it inside .git.
        #expect(guardian.check(tree.path("link/objects"), context: manual).isBlocked)
    }

    @Test("A location check refuses only what its location refuses, and that stays refused whatever is there")
    func locationRefusal() throws {
        let tree = try TempTree()
        try tree.directory("home/Projects/app/.git")
        let guardian = SafetyGuard(home: tree.path("home"), volumes: emptyVolumes, isRunningAsRoot: false)

        let system = try #require(guardian.locationRefusal(of: "/System/Library", rule: nil, context: manual))
        #expect(system == guardian.check("/System/Library", context: manual).reasons)
        #expect(guardian.check("/System/Library", size: 1 << 40, context: manual, isRepository: true).isBlocked)

        // A repository blocks an automatic run, but that is a fact about what is there, judged once it is known: the
        // location alone refuses nothing.
        let app = tree.path("home/Projects/app")
        let custom = CleanupContext.automatic(AutomationContext(jobID: "j", customPaths: [tree.path("home/Projects")]))
        #expect(guardian.check(app, context: custom, isRepository: true).isBlocked)
        #expect(guardian.locationRefusal(of: app, rule: nil, context: custom) == nil)
        #expect(guardian.locationRefusal(of: app, rule: nil, context: manual) == nil, "warnings aren't refusals")
    }
}

@Suite("Safety verdict reasons")
struct VerdictEntryTests {
    @Test("Each reason keeps its own decision, whatever order they were raised in")
    func decisionPerReason() {
        let rule = Rule(id: "db", name: "Database", paths: ["~/db"], safety: SafetySpec(level: .protected))
        let verdict = testGuard().check(
            "/Users/tester/Projects/app", rule: rule, context: .manual, isRepository: true)
        #expect(verdict.decision == .block)
        #expect(verdict.entries.first { $0.reason.contains("Don't touch") }?.decision == .block)
        #expect(verdict.entries.first { $0.reason.contains("git repository") }?.decision == .confirm)
        #expect(verdict.reasons == verdict.entries.map(\.reason))
    }

    @Test("A command's item reasons keep their own decisions")
    func commandItemReasons() throws {
        let tree = try TempTree()
        try tree.directory("home/tools/a/.git")
        var rule = Rule(
            id: "tools", name: "Tools", paths: [tree.path("home/tools")], granularity: .children, safety: SafetySpec(level: .protected),
            action: ActionSpec(itemCommand: ["swift", "{path}"]))
        rule.isBuiltin = true
        let command = PlannedCommand(
            ruleID: "tools", arguments: ["swift", tree.path("home/tools/a")], estimatedBytes: 1, itemPath: tree.path("home/tools/a"))
        let verdict = sandboxExecutor(tree, rules: [rule]).verdict(for: command, context: .manual)
        #expect(verdict.decision == .block)
        #expect(verdict.entries.first { $0.reason.contains("git repository") }?.decision == .confirm)
    }
}

/// APFS treats `Library`, `library` and `LIBRARY` (and NFC/NFD spellings of a name) as the same folder,
/// so every protected list must match regardless of how the path is spelled.
@Suite("Safety guard: case and Unicode spellings")
struct SafetyGuardSpellingTests {
    let manual = CleanupContext.manual
    let automatic = CleanupContext.automatic(AutomationContext(jobID: "test"))

    /// A sandbox home on disk holding the usual protected folders.
    private func sandbox(protectedPaths: [String] = [], rules: [Rule] = []) throws -> (TempTree, SafetyGuard) {
        let tree = try TempTree()
        for folder in ["Library/Keychains", "Library/Caches", ".ssh", "Documents", "Downloads", "Projects/app/.git"] {
            try tree.directory(folder)
        }
        let guardian = SafetyGuard(
            home: tree.root, userProtectedPaths: protectedPaths, protectedRules: rules, volumes: emptyVolumes, isRunningAsRoot: false)
        return (tree, guardian)
    }

    @Test(
        "Case variants of protected home locations are blocked",
        arguments: [
            "~/library", "~/LIBRARY", "~/LIBRARY/Keychains", "~/Library/keychains/login.keychain-db", "~/.SSH", "~/.Ssh/id_ed25519",
            "~/documents", "~/DOCUMENTS", "~/library/caches", "~/Projects/app/.GIT", "~/Projects/app/.Git/objects",
        ])
    func caseVariantsOnDisk(path: String) throws {
        let (tree, guardian) = try sandbox()
        let expanded = PathUtil.expand(path, home: tree.root)
        #expect(guardian.check(expanded, context: manual).isBlocked, "\(path) must be blocked")
    }

    @Test("An upper-cased spelling of the whole home path is blocked")
    func upperCasedHome() throws {
        let (tree, guardian) = try sandbox()
        #expect(guardian.check(tree.root.uppercased(), context: manual).isBlocked)
        #expect(guardian.check(tree.root.uppercased() + "/LIBRARY", context: manual).isBlocked)
        #expect(guardian.check(tree.root.uppercased() + "/.SSH/config", context: manual).isBlocked)
    }

    @Test(
        "Case variants are blocked even when nothing exists on disk",
        arguments: [
            "/USERS", "/users/tester", "/USERS/TESTER", "/Users/tester/library", "/users/tester/LIBRARY/Keychains/x",
            "/Users/tester/.SSH", "/Users/tester/documents", "/SYSTEM/Library/Frameworks", "/usr/BIN/ls", "/volumes/External",
            "/Users/tester/Pictures/Photos Library.PhotosLibrary/originals/0",
        ])
    func caseVariantsWithoutDisk(path: String) {
        #expect(testGuard().check(path, context: manual).isBlocked, "\(path) must be blocked")
    }

    @Test("Personal folders are recognised in any case")
    func personalCase() {
        let file = "/Users/tester/downloads/installer.dmg"
        #expect(testGuard().check(file, context: .manual).reasons == ["This is personal data, not a cache"])
        // A job listing `~/downloads` without an age limit must get the strict personal-folder treatment.
        let noAge = CleanupContext.automatic(AutomationContext(jobID: "dl", customPaths: ["~/downloads"], olderThan: nil, usesTrash: true))
        #expect(testGuard().check(file, context: noAge).isBlocked)
    }

    @Test("Protected rules and user-protected paths match in any case")
    func protectedListsCase() {
        let rule = Rule(
            id: "db.postgres", name: "Postgres data", paths: ["~/Library/Application Support/Postgres"],
            safety: SafetySpec(level: .protected))
        let guardian = testGuard(protectedPaths: ["~/Work/Archive"], rules: [rule])
        #expect(guardian.check("/Users/tester/work/ARCHIVE/2020", context: manual).isBlocked)
        #expect(guardian.check("/Users/tester/WORK", context: manual).isBlocked)
        #expect(guardian.check("/Users/tester/library/application support/POSTGRES/var-16", context: manual).isBlocked)
    }

    @Test("NFC and NFD spellings of a protected name are the same folder")
    func unicodeNormalization() throws {
        let nfc = "Caf\u{E9}"
        let nfd = "Cafe\u{301}"
        let fromNFC = testGuard(protectedPaths: ["~/\(nfc)"])
        #expect(fromNFC.check("/Users/tester/\(nfd)/menu.txt", context: manual).isBlocked)
        let fromNFD = testGuard(protectedPaths: ["~/\(nfd)"])
        #expect(fromNFD.check("/Users/tester/\(nfc)/menu.txt", context: manual).isBlocked)
        #expect(fromNFD.check("/Users/tester/CAF\u{C9}", context: manual).isBlocked)

        let (tree, guardian) = try sandbox(protectedPaths: ["~/\(nfc)"])
        try tree.directory(nfd + "/2024")
        #expect(guardian.check(tree.path(nfc + "/2024"), context: manual).isBlocked)
        #expect(guardian.check(tree.path(nfd + "/2024"), context: manual).isBlocked)
    }
}

@Suite("Safety guard: protected lists")
struct SafetyGuardProtectedListTests {
    let manual = CleanupContext.manual

    @Test(
        "Sealed roots are blocked, not only what's inside them",
        arguments: [
            "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share",
            "/Users/tester/Library/Application Support/1Password", "/Users/tester/Library/Group Containers/2BUA8C4S2C.com.1password",
            "/Users/tester/Library/Group Containers/group.com.docker",
        ])
    func sealedRoots(path: String) {
        #expect(testGuard().check(path, context: manual).isBlocked, "\(path) must be blocked")
    }

    @Test(
        "Calendars and password managers are sealed",
        arguments: [
            "/Users/tester/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb",
            "/Users/tester/Library/Group Containers/2BUA8C4S2C.com.agilebits/Library",
            "/Users/tester/Library/Containers/com.agilebits.onepassword7/Data",
            "/Users/tester/Library/Containers/com.1password.1password/Data",
            "/Users/tester/Library/Application Support/Bitwarden/data.json",
            "/Users/tester/Library/Containers/com.bitwarden.desktop/Data",
        ])
    func calendarsAndPasswordManagers(path: String) {
        #expect(testGuard().check(path, context: manual).isBlocked, "\(path) must be blocked")
    }

    @Test("Protected glob rules also block the folders that contain their matches")
    func protectedGlobContainers() {
        let rule = Rule(
            id: "db.homebrew-postgres", name: "Homebrew Postgres", paths: ["~/brew/var/postgresql@*", "~/Media/*.photoslibrary"],
            safety: SafetySpec(level: .protected))
        let guardian = testGuard(rules: [rule])
        #expect(guardian.check("/Users/tester/brew/var/postgresql@16", context: manual).isBlocked)
        #expect(guardian.check("/Users/tester/brew/var/postgresql@16/base", context: manual).isBlocked)
        #expect(guardian.check("/Users/tester/brew/var", context: manual).isBlocked)
        #expect(guardian.check("/Users/tester/brew", context: manual).isBlocked)
        #expect(guardian.check("/Users/tester/Media", context: manual).isBlocked)
        #expect(!guardian.check("/Users/tester/brew/var/log", context: manual).isBlocked)
        #expect(!guardian.check("/Users/tester/Media/clip.mov", context: manual).isBlocked)
    }

    @Test("User-protected paths are matched through symlinks")
    func userProtectedSymlink() throws {
        let tree = try TempTree()
        try tree.directory("home")
        try tree.directory("elsewhere/work/2020")
        try FileManager.default.createSymbolicLink(atPath: tree.path("home/work"), withDestinationPath: tree.path("elsewhere/work"))
        let guardian = SafetyGuard(home: tree.path("home"), userProtectedPaths: ["~/work"], volumes: emptyVolumes, isRunningAsRoot: false)
        #expect(guardian.check(tree.path("elsewhere/work/2020"), context: manual).isBlocked)
        #expect(guardian.check(tree.path("elsewhere/work"), context: manual).isBlocked)
        #expect(guardian.check(tree.path("elsewhere"), context: manual).isBlocked)
        #expect(guardian.check(tree.path("home/work/2020"), context: manual).isBlocked)
    }

    @Test("Only `~` and `~/` are expanded; `~name` paths are refused", arguments: ["~foo/x", "~root", "~tester/Library/Caches/x"])
    func tildeUserPaths(path: String) {
        let verdict = testGuard().check(path, context: manual)
        #expect(verdict.isBlocked)
        #expect(verdict.reasons == ["Path must be absolute"])
    }

    @Test("Folders containing repositories need confirmation unless a safe rule claims them")
    func containsRepository() {
        let guardian = testGuard()
        let path = "/Users/tester/Projects"
        let automatic = CleanupContext.automatic(AutomationContext(jobID: "a", customPaths: ["~/Projects"]))
        let byHand = guardian.check(path, context: .manual, containsRepository: true)
        #expect(byHand.decision == .confirm)
        #expect(byHand.reasons.contains("This folder contains git repositories"))
        #expect(guardian.check(path, context: automatic, containsRepository: true).isBlocked)

        let safe = Rule(
            id: "dev.builds", name: "Builds", paths: ["~/Projects"], safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        #expect(guardian.check(path, rule: safe, context: .manual, containsRepository: true).decision == .allow)
        #expect(guardian.check(path, rule: safe, context: automatic, containsRepository: true).decision == .allow)

        let review = Rule(
            id: "dev.builds", name: "Builds", paths: ["~/Projects"], safety: SafetySpec(level: .review), action: ActionSpec(remove: true))
        let reviewed = guardian.check(path, rule: review, context: .manual, containsRepository: true)
        #expect(reviewed.reasons.contains("This folder contains git repositories"))
        let optedIn = CleanupContext.automatic(AutomationContext(jobID: "a", allowReview: true))
        #expect(guardian.check(path, rule: review, context: optedIn, containsRepository: true).isBlocked)
    }
}

@Suite("Safety guard: automation limits")
struct SafetyGuardAutomationTests {
    let safeRule = Rule(
        id: "xcode.derived-data", name: "DerivedData", paths: ["~/Library/Developer/Xcode/DerivedData"],
        granularity: .children, safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
    let path = "/Users/tester/Library/Developer/Xcode/DerivedData/App-abc"
    let automatic = CleanupContext.automatic(AutomationContext(jobID: "test"))

    /// A guard on a volume with 1000 bytes in use, so sizes read as tenths of a percent.
    private var guardian: SafetyGuard {
        SafetyGuard(
            home: "/Users/tester", volumes: emptyVolumes, isRunningAsRoot: false,
            volumeCapacity: { _ in VolumeCapacity(name: "Test", mountPoint: "/", total: 2000, freeNow: 1000, available: 1000) })
    }

    @Test("By hand, an item over 10% of used space needs confirmation")
    func manualVolumeShare() {
        let manual = CleanupContext.manual
        #expect(guardian.check(path, size: 100, rule: safeRule, context: manual).decision == .allow)
        #expect(guardian.check(path, size: 150, rule: safeRule, context: manual).decision == .confirm)
        #expect(guardian.check(path, size: 300, rule: safeRule, context: manual).decision == .confirm)
    }

    @Test("Automatically, an item up to 25% of used space is allowed and anything bigger is blocked")
    func automaticVolumeShare() {
        #expect(guardian.check(path, size: 150, rule: safeRule, context: automatic).decision == .allow)
        #expect(guardian.check(path, size: 250, rule: safeRule, context: automatic).decision == .allow)
        #expect(guardian.check(path, size: 300, rule: safeRule, context: automatic).isBlocked)
    }

    @Test("Pattern rules are in scope only under their roots, outside their exclusions")
    func patternScope() {
        let rule = Rule(
            id: "node.modules", name: "node_modules", match: PatternSpec(names: ["node_modules"], exclude: ["~/Code/vendor"]),
            safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        let guardian = testGuard()
        #expect(guardian.check("/Users/tester/Code/app/node_modules", rule: rule, context: automatic).decision == .allow)
        #expect(guardian.check("/opt/work/app/node_modules", rule: rule, context: automatic).isBlocked)
        #expect(guardian.check("/Users/tester/Code/vendor/lib/node_modules", rule: rule, context: automatic).isBlocked)
        #expect(guardian.check("/Users/tester/code/VENDOR/lib/node_modules", rule: rule, context: automatic).isBlocked)
        #expect(guardian.check("/Users/tester/.npm/_npx/abc/node_modules", rule: rule, context: automatic).isBlocked)
        #expect(guardian.check("/Users/tester/Code/Tool.app/Contents/node_modules", rule: rule, context: automatic).isBlocked)
        #expect(guardian.check("/Users/tester/Code/app/node_modules/x", rule: rule, context: automatic).isBlocked)
    }

    @Test("Pattern rules without roots search the configured developer roots")
    func patternRoots() {
        let rule = Rule(
            id: "node.modules", name: "node_modules", match: PatternSpec(names: ["node_modules"]),
            safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        let guardian = SafetyGuard(home: "/Users/tester", volumes: emptyVolumes, isRunningAsRoot: false, patternRoots: ["/opt/work"])
        #expect(guardian.check("/opt/work/app/node_modules", rule: rule, context: automatic).decision == .allow)
        #expect(guardian.check("/Users/tester/app/node_modules", rule: rule, context: automatic).isBlocked)
        let ownRoots = Rule(
            id: "node.modules", name: "node_modules", match: PatternSpec(names: ["node_modules"], roots: ["~/Code"]),
            safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        #expect(guardian.check("/Users/tester/Code/app/node_modules", rule: ownRoots, context: automatic).decision == .allow)
        #expect(guardian.check("/opt/work/app/node_modules", rule: ownRoots, context: automatic).isBlocked)
    }

    @Test("A path is checked exactly as given: trailing spaces name a different item")
    func noTrimming() throws {
        let guardian = testGuard()
        let manual = CleanupContext.manual
        #expect(guardian.check("/Users/tester/Documents", context: manual).isBlocked)
        let spaced = guardian.check("/Users/tester/Documents ", context: manual)
        #expect(spaced.decision == .confirm)

        let tree = try TempTree()
        try tree.file("report /a", bytes: 50_000)
        try tree.file("report/b", bytes: 4_000)
        #expect(try scan(tree.path("report ")).root.size == tree.allocated("report /a"))
    }

    @Test("By hand, a safe rule outside its own locations counts as no rule: the person confirms")
    func manualOutsideScope() {
        let rule = Rule(
            id: "node.modules", name: "node_modules", match: PatternSpec(names: ["node_modules"]),
            safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        let guardian = testGuard()
        let manual = CleanupContext.manual
        #expect(guardian.check("/Users/tester/Code/app/node_modules", rule: rule, context: manual).decision == .allow)
        let tool = guardian.check("/Users/tester/.vscode/extensions/ext/node_modules", rule: rule, context: manual)
        #expect(tool.decision == .confirm)
        #expect(guardian.check("/opt/work/app/node_modules", rule: rule, context: manual).decision == .confirm)
    }

    @Test("Automatic scope must hold for the path with its parent's symlinks resolved, not only as written")
    func scopeOfResolvedParent() throws {
        let tree = try TempTree()
        try tree.file("home/cache/real/x", bytes: 100)
        try tree.file("home/jobs/old/keep/x", bytes: 100)
        try tree.file("home/Important/data/x", bytes: 100)
        try FileManager.default.createSymbolicLink(atPath: tree.path("home/cache/link"), withDestinationPath: tree.path("home/Important"))
        let important = tree.path("home/Important")
        try FileManager.default.createSymbolicLink(atPath: tree.path("home/jobs/old/link"), withDestinationPath: important)
        let guardian = SafetyGuard(home: tree.path("home"), volumes: emptyVolumes, isRunningAsRoot: false)

        let rule = Rule(
            id: "c", name: "c", paths: [tree.path("home/cache")], granularity: .children, safety: SafetySpec(level: .safe),
            action: ActionSpec(remove: true))
        #expect(guardian.check(tree.path("home/cache/real"), rule: rule, context: automatic).decision == .allow)
        #expect(guardian.check(tree.path("home/cache/link/data"), rule: rule, context: automatic).isBlocked)

        let job = CleanupContext.automatic(AutomationContext(jobID: "j", customPaths: [tree.path("home/jobs/old")]))
        #expect(guardian.check(tree.path("home/jobs/old/keep"), context: job).decision == .allow)
        #expect(guardian.check(tree.path("home/jobs/old/link/data"), context: job).isBlocked)
    }

    @Test("Automatic scope checks see rule and job paths written through a symlink as the scanned, resolved paths")
    func scopeThroughSymlinks() {
        let guardian = testGuard()
        let rule = Rule(id: "tmp.cache", name: "Temp cache", paths: ["/tmp/spacekit-none/cache"], safety: SafetySpec(level: .safe))
        let item = "/private/tmp/spacekit-none/cache"
        #expect(guardian.check(item, rule: rule, context: automatic).decision == .allow)
        let job = CleanupContext.automatic(AutomationContext(jobID: "a", customPaths: ["/tmp/spacekit-none"]))
        #expect(!guardian.check(item + "/old", context: job).reasons.contains { $0.hasPrefix("Automatic jobs only remove") })
    }

    @Test("An item spelled through a symlinked parent (/var for /private/var) keeps its rule's recognition")
    func itemSpelledThroughSymlink() throws {
        let tree = try TempTree()
        try tree.file("cache/a/x", bytes: 100)
        try tree.file("elsewhere/b/x", bytes: 100)
        // The temporary folder lives under /private/var, which /var links to.
        let written = tree.path("cache").replacingOccurrences(of: "/private/var/", with: "/var/")
        try #require(written != tree.path("cache"))
        let guardian = SafetyGuard(home: tree.path("home"), volumes: emptyVolumes, isRunningAsRoot: false)
        let rule = Rule(
            id: "c", name: "c", paths: [written], granularity: .children, safety: SafetySpec(level: .safe),
            action: ActionSpec(remove: true))
        let manual = CleanupContext.manual

        #expect(guardian.check(written + "/a", rule: rule, context: manual).decision == .allow)
        #expect(guardian.check(written + "/a", rule: rule, context: automatic).decision == .allow)
        let job = CleanupContext.automatic(AutomationContext(jobID: "j", customPaths: [written]))
        #expect(guardian.check(written + "/a", context: job).decision == .allow)

        // Where the spelling resolves to still decides.
        try FileManager.default.createSymbolicLink(atPath: tree.path("cache/link"), withDestinationPath: tree.path("elsewhere"))
        #expect(guardian.check(written + "/link/b", rule: rule, context: manual).decision == .confirm)
        #expect(guardian.check(written + "/link/b", rule: rule, context: automatic).isBlocked)
    }
}
