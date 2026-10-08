import Foundation
import Synchronization
import Testing

@testable import SpaceKitCore

/// The removal module: one target per item, read from the disk once, is what the guard judges and what leaves.
/// Anything that changed at its path after that (a symlink swapped in, a different folder put in its place, a volume
/// mounted inside it) is refused or left, never followed.
@Suite("Removal: one resolved target")
struct RemovalTests {
    let manual = CleanupContext.manual

    func target(_ tree: TempTree, _ relative: String, probing: Bool = true) -> RemovalTarget {
        sandboxExecutor(tree).remover.target(of: CleanupItem(path: tree.path(relative), size: 0), probingRepositories: probing)
    }

    @Test("The target pins what is at the path, where it is resolved, and the guard's facts")
    func targetFacts() throws {
        let tree = try TempTree()
        try tree.file("real/app/.git/HEAD", bytes: 10)
        try FileManager.default.createSymbolicLink(atPath: tree.path("link"), withDestinationPath: tree.path("real"))

        let probed = target(tree, "link/app")
        #expect(probed.path == tree.path("link/app"))
        #expect(probed.resolvedPath == tree.path("real/app"))
        #expect(probed.spellings.contains(tree.path("real/app")))
        #expect(probed.isFolder)
        #expect(probed.isRepository, "probed on the disk although the item recorded none")
        var st = stat()
        #expect(lstat(tree.path("real/app"), &st) == 0)
        #expect(probed.identity == RemovalTarget.Identity(st))

        let recorded = target(tree, "link/app", probing: false)
        #expect(!recorded.isRepository, "a review uses what the scan recorded")
        #expect(target(tree, "missing").identity == nil)
    }

    @Test("An item swapped for a symlink after it was checked is refused, by delete and by Trash")
    func itemSwappedForSymlink() throws {
        for method in [Remover.Method.delete, .trash] {
            let tree = try TempTree()
            try tree.file("home/cache/item/x", bytes: 100)
            try tree.file("home/victim/keep", bytes: 100)
            let remover = sandboxExecutor(tree).remover
            let checked = target(tree, "home/cache/item")

            try FileManager.default.removeItem(atPath: tree.path("home/cache/item"))
            try FileManager.default.createSymbolicLink(atPath: tree.path("home/cache/item"), withDestinationPath: tree.path("home/victim"))

            #expect(throws: (any Error).self) { try remover.remove(checked, by: method, context: manual) }
            #expect(onDisk(tree.path("home/cache/item")), "the link stays: it isn't what was checked")
            #expect(onDisk(tree.path("home/victim/keep")))
            #expect(!onDisk(tree.path("home/.Trash/item")))
        }
    }

    /// The executor's `device` seam is read first when deletion starts, after the entry was checked: the swap lands in
    /// the moment between that check and opening the folder to empty it.
    @Test("A folder renamed into the item's place after the entry check is refused, not deleted")
    func folderSwappedAfterEntryCheck() throws {
        let tree = try TempTree()
        try tree.file("home/cache/item/x", bytes: 100)
        try tree.file("home/victim/keep", bytes: 100)
        let flags = RaceFlags()
        let item = tree.path("home/cache/item")
        let aside = tree.path("home/cache/aside")
        let victim = tree.path("home/victim")
        var executor = sandboxExecutor(tree)
        executor.device = { fd in
            if !flags.swapped.exchange(true, ordering: .acquiringAndReleasing) {
                _ = rename(item, aside)
                _ = rename(victim, item)
            }
            return SafeRemoval.device(of: fd)
        }
        let checked = target(tree, "home/cache/item")

        #expect(throws: SafeRemoval.Refused.self) { try executor.remover.remove(checked, by: .delete, context: manual) }
        let swapped = flags.swapped.load(ordering: .acquiring)
        #expect(swapped, "the swap never happened; the test proved nothing")
        #expect(onDisk(tree.path("home/cache/item/keep")), "the folder swapped in isn't what was checked")
        #expect(onDisk(tree.path("home/cache/aside/x")))
    }

    /// The second device read is the item's own handle, once it is open and checked: the item moves away and a file
    /// takes its place before the walk empties it and removes its name.
    @Test("A file put in the item's place while it is emptied stays")
    func fileInItemsPlaceStays() throws {
        let tree = try TempTree()
        try tree.file("home/cache/item/x", bytes: 100)
        let reads = Atomic<Int>(0)
        let item = tree.path("home/cache/item")
        let aside = tree.path("home/cache/aside")
        var executor = sandboxExecutor(tree)
        executor.device = { fd in
            if reads.add(1, ordering: .acquiringAndReleasing).newValue == 2 {
                _ = rename(item, aside)
                FileManager.default.createFile(atPath: item, contents: Data([1]))
            }
            return SafeRemoval.device(of: fd)
        }
        let checked = target(tree, "home/cache/item")

        // The item's contents went before its name turned out to be taken: a deletion that stopped part way.
        #expect(throws: Remover.Interrupted.self) { try executor.remover.remove(checked, by: .delete, context: manual) }
        #expect(reads.load(ordering: .acquiring) >= 2, "the swap never happened; the test proved nothing")
        #expect(onDisk(item), "the file in the item's place isn't the item")
        #expect(!onDisk(tree.path("home/cache/aside/x")), "the item's own contents went")
    }

    @Test("A parent folder replaced after the check (A-B-A) is refused, even holding the same file")
    func parentSwappedAndBack() throws {
        let tree = try TempTree()
        try tree.file("parent/item", bytes: 100)
        try tree.directory("elsewhere")
        let remover = sandboxExecutor(tree).remover
        let checked = target(tree, "parent/item")

        // A: the checked folder moves away. B: a symlink stands in for it. A': a new folder with a hard link to the
        // same file, so the item itself still matches.
        #expect(rename(tree.path("parent"), tree.path("parent-old")) == 0)
        try FileManager.default.createSymbolicLink(atPath: tree.path("parent"), withDestinationPath: tree.path("elsewhere"))
        #expect(throws: (any Error).self) { try remover.remove(checked, by: .delete, context: manual) }
        #expect(unlink(tree.path("parent")) == 0)
        try tree.directory("parent")
        #expect(link(tree.path("parent-old/item"), tree.path("parent/item")) == 0)

        #expect(throws: (any Error).self) { try remover.remove(checked, by: .delete, context: manual) }
        #expect(onDisk(tree.path("parent/item")))
        #expect(onDisk(tree.path("parent-old/item")))
    }

    /// A test can't mount a volume, so it stands one in through the executor's device seam: the folder named `mnt`
    /// reads as being on another device, the way a volume mounted there after the guard's check would.
    @Test("A folder on another volume inside the item is left and reported; the rest is removed")
    func mountedSubtreeLeft() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/old/keep/x", bytes: 1_000)
        try tree.file("home/Projects/old/mnt/disk/y", bytes: 1_000)
        var executor = sandboxExecutor(tree)
        executor.device = { fd in
            var st = stat()
            guard fstat(fd, &st) == 0 else { return nil }
            return SafeRemoval.currentPath(of: fd)?.hasSuffix("/mnt") == true ? st.st_dev &+ 1 : st.st_dev
        }
        let scanned = try scan(tree.path("home"))
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/old"), size: 2_000)], useTrash: false)
        let report = manualRun(plan, with: executor)

        #expect(onDisk(tree.path("home/Projects/old/mnt/disk/y")), "nothing on the other volume is touched")
        #expect(!onDisk(tree.path("home/Projects/old/keep")))
        #expect(report.items.first?.outcome.isRemoved == true)
        #expect(report.warnings.contains { $0.contains("old/mnt") && $0.contains("another volume") })

        // The item's folder is still there, holding the volume, so the app and the TUI rescan it instead of dropping it.
        let removals = Removal.from(report)
        #expect(removals.map(\.partial) == [true])
        #expect(Removal.apply(removals, to: scanned))
        #expect(scanned.inconsistencies().isEmpty)
        #expect(scanned.node(at: tree.path("home/Projects/old/mnt/disk")) != nil)
        #expect(scanned.root.size == (try scan(tree.path("home"))).root.size)
    }

    @Test("A volume and an entry that can't be removed in one item: both stay and are reported, the rest is journaled")
    func mountedSubtreeAndLockedEntry() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/old/keep/x", bytes: 1_000)
        try tree.file("home/Projects/old/locked/z", bytes: 1_000)
        try tree.file("home/Projects/old/mnt/disk/y", bytes: 1_000)
        let locked = tree.path("home/Projects/old/locked/z")
        #expect(chflags(locked, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked, 0) }
        var executor = sandboxExecutor(tree)
        executor.device = { fd in
            var st = stat()
            guard fstat(fd, &st) == 0 else { return nil }
            return SafeRemoval.currentPath(of: fd)?.hasSuffix("/mnt") == true ? st.st_dev &+ 1 : st.st_dev
        }
        let gone = tree.allocated("home/Projects/old/keep/x")
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/old"), size: 3_000)], useTrash: false)
        let report = manualRun(plan, with: executor)

        #expect(!onDisk(tree.path("home/Projects/old/keep")))
        #expect(onDisk(locked))
        #expect(onDisk(tree.path("home/Projects/old/mnt/disk/y")))
        guard case .failed(let reason) = report.items.first?.outcome else {
            Issue.record("expected a failure, got \(String(describing: report.items.first?.outcome))")
            return
        }
        #expect(reason.contains("locked/z"), "the failure names the entry that couldn't be removed, not the volume")
        #expect(report.warnings.contains { $0.contains("old/mnt") && $0.contains("another volume") })
        #expect(report.partiallyFreed[tree.path("home/Projects/old")] == gone)
        #expect(journalEntries(tree).map(\.bytes) == [gone])
    }

    @Test("A target that changed before anything was deleted is refused as such, not as a deletion that stopped part way")
    func refusedBeforeDeleting() throws {
        let tree = try TempTree()
        try tree.file("home/cache/item/a", bytes: 1_000)
        let remover = sandboxExecutor(tree).remover
        let checked = target(tree, "home/cache/item")
        try FileManager.default.removeItem(atPath: tree.path("home/cache/item"))
        try tree.file("home/cache/item/b", bytes: 1_000)

        #expect(throws: SafeRemoval.Refused.self) { try remover.remove(checked, by: .delete, context: manual) }
        #expect(onDisk(tree.path("home/cache/item/b")))
    }

    @Test("A deletion refused before anything went is a refusal, not a deletion that stopped part way")
    func refusalsBeforeDeletingArentPartial() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/mnt/y", bytes: 1_000)
        var mounted = sandboxExecutor(tree)
        mounted.device = { fd in
            var st = stat()
            guard fstat(fd, &st) == 0 else { return nil }
            return SafeRemoval.currentPath(of: fd)?.hasSuffix("/mnt") == true ? st.st_dev &+ 1 : st.st_dev
        }
        let item = target(tree, "home/Projects/mnt")
        #expect(throws: SafeRemoval.Refused.self) { try mounted.remover.remove(item, by: .delete, context: manual) }

        var unreadable = sandboxExecutor(tree)
        unreadable.device = { _ in nil }
        #expect {
            try unreadable.remover.remove(item, by: .delete, context: manual)
        } throws: { error in
            !(error is Remover.Interrupted)
        }
        #expect(onDisk(tree.path("home/Projects/mnt/y")))
    }

    @Test("An item that is itself on another volume than its folder is refused")
    func mountedItemRefused() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/mnt/y", bytes: 1_000)
        var executor = sandboxExecutor(tree)
        executor.device = { fd in
            var st = stat()
            guard fstat(fd, &st) == 0 else { return nil }
            return SafeRemoval.currentPath(of: fd)?.hasSuffix("/mnt") == true ? st.st_dev &+ 1 : st.st_dev
        }
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/mnt"), size: 1_000)], useTrash: false)
        let report = manualRun(plan, with: executor)
        #expect(onDisk(tree.path("home/Projects/mnt/y")))
        #expect(report.items.first?.outcome.isRemoved == false)
    }

    let automatic = CleanupContext.automatic(AutomationContext(jobID: "j"))

    /// An executor whose path-based Trash move fails the test: an automatic run must never call it.
    func handleOnlyExecutor(_ tree: TempTree) -> CleanupExecutor {
        var executor = sandboxExecutor(tree)
        executor.trash = { path in
            Issue.record("an automatic run moved \(path) to the Trash by path")
            return nil
        }
        return executor
    }

    /// The executor's `device` seam is read once the entry is checked, right before the move: the swap lands in the
    /// moment a move by path would follow it to the sealed folder.
    @Test("An automatic run moves to the Trash through the checked folder: a parent swapped for a symlink doesn't redirect it")
    func automaticTrashThroughHandle() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/cache/item/x", bytes: 100)
        try tree.file("home/Sealed/item/keep", bytes: 100)
        let flags = RaceFlags()
        let cache = tree.path("home/Projects/cache")
        let aside = tree.path("home/Projects/aside")
        let sealed = tree.path("home/Sealed")
        var executor = handleOnlyExecutor(tree)
        executor.device = { fd in
            if !flags.swapped.exchange(true, ordering: .acquiringAndReleasing) {
                _ = rename(cache, aside)
                _ = symlink(sealed, cache)
            }
            return SafeRemoval.device(of: fd)
        }
        let checked = target(tree, "home/Projects/cache/item")

        let removed = try executor.remover.remove(checked, by: .trash, context: automatic)
        let swapped = flags.swapped.load(ordering: .acquiring)
        #expect(swapped, "the swap never happened; the test proved nothing")
        #expect(onDisk(tree.path("home/Sealed/item/keep")), "the sealed folder stays where it is")
        #expect(removed.trashedTo == tree.path("home/.Trash/item"))
        #expect(onDisk(tree.path("home/.Trash/item/x")), "the checked item went, from where it was moved")
        #expect(!onDisk(tree.path("home/Projects/aside/item")))
    }

    @Test("An automatic run never overwrites a Trash entry, and leaves an item on another volume than the Trash")
    func automaticTrashNames() throws {
        let tree = try TempTree()
        try tree.file("home/.Trash/old/earlier", bytes: 10)
        try tree.file("home/Projects/old/x", bytes: 1_000)
        try tree.file("home/Projects/other/y", bytes: 1_000)
        let executor = handleOnlyExecutor(tree)
        let rule = cacheRule(tree, level: .review, paths: ["home/Projects"])
        var ruled = executor
        ruled.rules = [rule.id: rule]
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/old"), size: 1_000, ruleID: rule.id)], useTrash: false)
        let report = ruled.execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j", allowReview: true)), dryRun: false)
        #expect(report.items.first?.outcome.trashedTo == tree.path("home/.Trash/old 2"))
        #expect(onDisk(tree.path("home/.Trash/old/earlier")) && onDisk(tree.path("home/.Trash/old 2/x")))
        #expect(journalEntries(tree).first?.trashedTo == tree.path("home/.Trash/old 2"))

        // A test can't mount a volume: the device seam puts the item's folder on another one than the Trash.
        var elsewhere = handleOnlyExecutor(tree)
        let trashDevice = try #require(identity(tree.path("home/.Trash"))).device
        elsewhere.device = { fd in SafeRemoval.device(of: fd).map { $0 == trashDevice ? $0 &+ 1 : $0 } }
        let other = target(tree, "home/Projects/other")
        #expect(throws: SafeRemoval.Refused.self) { try elsewhere.remover.remove(other, by: .trash, context: automatic) }
        #expect(onDisk(tree.path("home/Projects/other/y")))
    }

    @Test("A move by handle fits a long name beside its number, and stops with a clear message once every name is taken")
    func automaticTrashNameLimits() throws {
        let tree = try TempTree()
        let long = String(repeating: "é", count: 127)  // 254 bytes: room for the name, not for " 2" beside it
        try tree.file("home/.Trash/\(long)/earlier", bytes: 10)
        try tree.file("home/Projects/\(long)/x", bytes: 100)
        let executor = handleOnlyExecutor(tree)
        let removed = try executor.remover.remove(target(tree, "home/Projects/\(long)"), by: .trash, context: automatic)
        let fitted = String(repeating: "é", count: 126) + " 2"
        #expect(Remover.trashName(long, attempt: 2) == fitted && fitted.utf8.count <= Remover.longestName)
        #expect(removed.trashedTo == tree.path("home/.Trash/\(fitted)"))
        #expect(onDisk(tree.path("home/.Trash/\(fitted)/x")))

        try tree.file("home/Projects/full/x", bytes: 100)
        for attempt in 1...Remover.trashNameAttempts { try tree.directory("home/.Trash/" + Remover.trashName("full", attempt: attempt)) }
        do {
            _ = try executor.remover.remove(target(tree, "home/Projects/full"), by: .trash, context: automatic)
            Issue.record("moved although every name was taken")
        } catch let refused as SafeRemoval.Refused {
            #expect(refused.localizedDescription.contains("already holds \(Remover.trashNameAttempts) items named like full"))
        }
        #expect(onDisk(tree.path("home/Projects/full/x")))
    }

    /// The home Trash is opened only as the person's own real folder; the tests use a sandbox home's Trash.
    @Test("The Trash is created when missing, and refused when it is a symlink or someone else's")
    func openingTheTrash() throws {
        let tree = try TempTree()
        try tree.directory("home")
        let trash = tree.path("home/.Trash")
        let created = try Remover.openTrash(at: trash)
        close(created)
        var st = stat()
        #expect(lstat(trash, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR && st.st_mode & 0o777 == 0o700)
        #expect(throws: SafeRemoval.Refused.self) { try Remover.openTrash(at: trash, user: getuid() &+ 1) }

        try tree.directory("elsewhere")
        let linked = tree.path("linked/.Trash")
        try tree.directory("linked")
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: tree.path("elsewhere"))
        #expect(throws: (any Error).self) { try Remover.openTrash(at: linked) }
    }

    @Test("A move to the Trash that took something other than the checked item is reported, not called removed")
    func trashVerifiedAfterwards() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/old/x", bytes: 1_000)
        try tree.file("home/Projects/other/y", bytes: 1_000)
        var executor = sandboxExecutor(tree)
        let move = executor.trash
        let aside = tree.path("home/Projects/moved-aside")
        let other = tree.path("home/Projects/other")
        // The swap lands in the moment between the identity check and the move.
        executor.trash = { path in
            try FileManager.default.moveItem(atPath: path, toPath: aside)
            try FileManager.default.moveItem(atPath: other, toPath: path)
            return try move(path)
        }
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/old"), size: 1_000)], useTrash: true)
        let report = manualRun(plan, with: executor)
        let outcome = try #require(report.items.first?.outcome)
        #expect(!outcome.isRemoved)
        #expect(report.failures.first?.reason.contains(".Trash") == true, "says where the wrong item went")
        #expect(journalEntries(tree).isEmpty)
    }

    @Test("A move to the Trash that doesn't say where the item went is reported, not called removed")
    func trashWithoutDestination() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/old/x", bytes: 1_000)
        var executor = sandboxExecutor(tree)
        let move = executor.trash
        executor.trash = { path in
            _ = try move(path)
            return nil
        }
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/old"), size: 1_000)], useTrash: true)
        let report = manualRun(plan, with: executor)
        let failure = try #require(report.failures.first)
        #expect(failure.reason.contains("Trash"))
        #expect(report.hasProblems)
        #expect(journalEntries(tree).isEmpty)
    }

    /// FAT and exFAT number a file by where its entry sits, and an empty file has nothing else to go by, so moving
    /// one gives it a new inode. A test can't make such a volume; the executor's `keepsInodes` seam stands one in,
    /// and the Trash stand-in hands back a copy of what it moved, which has a new inode too.
    @Test("An empty file moved to the Trash on a volume without stable inodes is checked by what it is")
    func trashWithoutStableInodes() throws {
        for (bytes, keepsInodes, removed) in [(0, false, true), (0, true, false), (1_000, false, false)] {
            let tree = try TempTree()
            let file = try tree.file("home/Projects/f", bytes: bytes)
            var executor = sandboxExecutor(tree)
            let move = executor.trash
            executor.keepsInodes = { _ in keepsInodes }
            executor.trash = { path in
                let destination = try #require(try move(path))
                let copy = destination + ".copy"
                try FileManager.default.copyItem(atPath: destination, toPath: copy)
                try FileManager.default.removeItem(atPath: destination)
                try FileManager.default.moveItem(atPath: copy, toPath: destination)
                return destination
            }
            let plan = CleanupPlan(items: [CleanupItem(path: file, kind: .file, size: tree.allocated("home/Projects/f"))], useTrash: true)
            let report = manualRun(plan, with: executor)
            let outcome = try #require(report.items.first?.outcome)
            #expect(outcome.isRemoved == removed, "\(bytes) bytes, inodes kept: \(keepsInodes)")
            #expect(onDisk(tree.path("home/.Trash/f")))
        }
    }

    @Test("A move to the Trash of the checked item records where it went")
    func trashMovesCheckedItem() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/old/x", bytes: 1_000)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/old"), size: 1_000)], useTrash: true)
        let report = manualRun(plan, with: sandboxExecutor(tree))
        #expect(report.items.first?.outcome.trashedTo == tree.path("home/.Trash/old"))
        #expect(onDisk(tree.path("home/.Trash/old/x")))
    }

    @Test("One place decides Trash or delete")
    func trashOrDelete() throws {
        let tree = try TempTree()
        try tree.file("home/cache/a", bytes: 10)
        try tree.file("home/.Trash/b", bytes: 10)
        let safe = cacheRule(tree, level: .safe, paths: ["home/cache"])
        let review = cacheRule(tree, level: .review, paths: ["home/cache"])
        let automatic = CleanupContext.automatic(AutomationContext(jobID: "j"))
        var executor = sandboxExecutor(tree)

        #expect(!executor.remover.isInsideTrash(target(tree, "home/cache/a")))
        #expect(executor.remover.isInsideTrash(target(tree, "home/.Trash/b")))
        #expect(executor.remover.method(inTrash: false, useTrash: false, rule: safe, context: manual) == .delete)
        #expect(executor.remover.method(inTrash: false, useTrash: true, rule: safe, context: manual) == .trash)
        #expect(executor.remover.method(inTrash: false, useTrash: false, rule: safe, context: automatic) == .delete)
        #expect(executor.remover.method(inTrash: false, useTrash: false, rule: review, context: automatic) == .trash)
        #expect(executor.remover.method(inTrash: true, useTrash: true, rule: nil, context: manual) == .delete)
        #expect(executor.remover.method(inTrash: true, useTrash: true, rule: nil, context: automatic) == nil)
        executor.alwaysTrash = true
        #expect(executor.remover.method(inTrash: false, useTrash: false, rule: safe, context: manual) == .trash)
        #expect(executor.remover.method(inTrash: true, useTrash: false, rule: safe, context: manual) == .delete)
    }
}

@Suite("Safety guard: facts from the removal target")
struct SafetyGuardTargetTests {
    let manual = CleanupContext.manual

    @Test("The guard judges the repository and size facts the target carries")
    func readsTargetFacts() throws {
        let tree = try TempTree()
        try tree.directory("home/Projects/app/.git")
        let guardian = SafetyGuard(
            home: tree.path("home"), volumes: emptyVolumes, isRunningAsRoot: false,
            volumeCapacity: { _ in VolumeCapacity(name: "Test", mountPoint: "/", total: 2000, freeNow: 1000, available: 1000) })
        let path = tree.path("home/Projects/app")
        let probed = RemovalTarget.at(
            path, home: guardian.home, size: 0, isRepository: false, containsRepository: false, probingRepositories: true)
        #expect(guardian.evaluate(probed, rule: nil, context: manual).reasons.contains("This folder is a git repository (source code)"))

        let large = RemovalTarget.at(
            path, home: guardian.home, size: 300, isRepository: false, containsRepository: false, probingRepositories: false)
        #expect(guardian.evaluate(large, rule: nil, context: manual).reasons.contains { $0.contains("of the disk's used space") })
    }

    @Test("A symlinked home is protected at its real location by the built-in lists, protected rules and your own")
    func symlinkedHome() throws {
        let tree = try TempTree()
        for folder in ["real/Documents", "real/.ssh", "real/Library/Caches/app", "real/Downloads"] { try tree.directory(folder) }
        try FileManager.default.createSymbolicLink(atPath: tree.path("home"), withDestinationPath: tree.path("real"))
        let credentials = Rule(
            id: "credentials", name: "Credentials", paths: ["~/.netrc", "~/.docker/config.json"], safety: SafetySpec(level: .protected),
            action: ActionSpec())
        let guardian = SafetyGuard(
            home: tree.path("home"), userProtectedPaths: ["~/Work/archive"], protectedRules: [credentials], volumes: emptyVolumes,
            isRunningAsRoot: false)
        func verdict(_ relative: String) -> SafetyVerdict {
            let target = RemovalTarget.at(
                tree.path(relative), home: guardian.home, size: 0, isRepository: false, containsRepository: false,
                probingRepositories: false)
            return guardian.evaluate(target, rule: nil, context: manual)
        }
        #expect(verdict("real").isBlocked)
        #expect(verdict("real/Documents").isBlocked)
        #expect(verdict("real/.ssh/id_ed25519").isBlocked)
        #expect(verdict("real/Library/Caches").isBlocked)
        #expect(verdict("real/Work/archive/2020").isBlocked, "a protected path that doesn't exist yet, under the real home")
        #expect(verdict("real/.netrc").isBlocked, "a protected rule's path, under the real home")
        #expect(verdict("real/.docker/config.json").isBlocked)
        #expect(verdict("real/Downloads/x.dmg").reasons == ["This is personal data, not a cache"])
        #expect(!verdict("real/Library/Caches/app").isBlocked)
    }
}
