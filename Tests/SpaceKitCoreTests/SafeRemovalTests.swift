import Foundation
import Synchronization
import Testing

@testable import SpaceKitCore

final class RaceFlags: Sendable {
    let swapped = Atomic<Bool>(false)
    let done = Atomic<Bool>(false)
}

/// Deletion that stays on directory handles: nothing outside the checked item is reachable, whatever is
/// swapped in while it runs, however deep it goes and whatever happens to the path above it.
@Suite("Safe removal")
struct SafeRemovalTests {
    func names(in path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    @Test("A subfolder swapped for a symlink mid-removal never leads the deletion outside the item")
    func swapRace() throws {
        let tree = try TempTree()
        let count = 4_000
        try tree.directory("item/sub")
        try tree.directory("victim")
        for index in 0..<count {
            FileManager.default.createFile(atPath: tree.path("item/sub/f\(index)"), contents: Data([1]))
            FileManager.default.createFile(atPath: tree.path("victim/f\(index)"), contents: Data([1]))
        }

        let flags = RaceFlags()
        let sub = tree.path("item/sub")
        let moved = tree.path("item/moved")
        let victim = tree.path("victim")
        let racer = Thread {
            // Swap once the removal is inside `sub`, so the rest of it would run through the link.
            while !flags.done.load(ordering: .acquiring) {
                let left = (try? FileManager.default.contentsOfDirectory(atPath: sub).count) ?? count
                if left < count * 9 / 10 {
                    if rename(sub, moved) == 0, symlink(victim, sub) == 0 { flags.swapped.store(true, ordering: .releasing) }
                    return
                }
            }
        }
        racer.start()
        let result = Result { try SafeRemoval.delete("item", inDirectory: tree.root) }
        flags.done.store(true, ordering: .releasing)
        while !racer.isFinished { usleep(1_000) }

        let swapped = flags.swapped.load(ordering: .acquiring)
        #expect(swapped, "the racer never swapped; the test proved nothing")
        #expect(names(in: victim).count == count, "files outside the item were deleted")
        #expect(throws: Never.self) { try result.get() }
        #expect(!onDisk(tree.path("item")))
    }

    @Test("A tree deeper than PATH_MAX is removed")
    func deepTree() throws {
        let tree = try TempTree()
        let component = String(repeating: "d", count: 200)
        let top = open(tree.root, O_RDONLY | O_DIRECTORY)
        #expect(mkdirat(top, "deep", 0o755) == 0)
        var fd = openat(top, "deep", O_RDONLY | O_DIRECTORY)
        close(top)
        for _ in 0..<12 {
            #expect(mkdirat(fd, component, 0o755) == 0)
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY)
            close(fd)
            fd = next
        }
        let file = openat(fd, "leaf", O_WRONLY | O_CREAT, 0o644)
        #expect(file >= 0)
        close(file)
        close(fd)

        try SafeRemoval.delete("deep", inDirectory: tree.root)
        #expect(!onDisk(tree.path("deep")))
    }

    @Test("Removal through an open handle works after search permission on an ancestor is taken away")
    func ancestorWithoutSearchPermission() throws {
        let tree = try TempTree()
        try tree.file("locked/parent/item/sub/file", bytes: 1_000)
        let fd = try SafeRemoval.openDirectory(tree.path("locked/parent"))
        defer { close(fd) }
        #expect(chmod(tree.path("locked"), 0o600) == 0)
        defer { chmod(tree.path("locked"), 0o755) }

        try SafeRemoval.delete("item", in: fd, directory: tree.path("locked/parent"))
        chmod(tree.path("locked"), 0o755)
        #expect(!onDisk(tree.path("locked/parent/item")))
    }

    @Test("A folder moved out from above the walk stops it before it climbs into the new parent")
    func ascendRace() throws {
        let tree = try TempTree()
        let count = 4_000
        try tree.directory("item/a/b")
        try tree.directory("victim")
        for index in 0..<count {
            FileManager.default.createFile(atPath: tree.path("item/a/b/f\(index)"), contents: Data([1]))
            FileManager.default.createFile(atPath: tree.path("victim/f\(index)"), contents: Data([1]))
        }

        let flags = RaceFlags()
        let a = tree.path("item/a")
        let b = tree.path("item/a/b")
        let victim = tree.path("victim")
        let racer = Thread {
            // Once the walk is inside `b`, move `a` into the victim and leave a link in its place: climbing out of
            // `a` by path or by ".." without checking would land in the victim.
            while !flags.done.load(ordering: .acquiring) {
                let left = (try? FileManager.default.contentsOfDirectory(atPath: b).count) ?? count
                if left < count * 9 / 10 {
                    if rename(a, victim + "/a") == 0, symlink(victim, a) == 0 { flags.swapped.store(true, ordering: .releasing) }
                    return
                }
            }
        }
        racer.start()
        let result = Result { try SafeRemoval.delete("item", inDirectory: tree.root) }
        flags.done.store(true, ordering: .releasing)
        while !racer.isFinished { usleep(1_000) }

        let swapped = flags.swapped.load(ordering: .acquiring)
        #expect(swapped, "the racer never swapped; the test proved nothing")
        let left = names(in: victim).filter { $0.hasPrefix("f") }
        #expect(left.count == count, "files outside the item were deleted")
        #expect(throws: SafeRemoval.Refused.self) { try result.get() }
    }

    @Test("A tree deeper than the open-file limit is removed with a handful of handles")
    func deeperThanFileLimit() throws {
        let tree = try TempTree()
        SafeRemovalTests.nest(300, in: tree.root)

        var original = rlimit()
        getrlimit(RLIMIT_NOFILE, &original)
        // The default soft limit of a login session and of a launchd agent.
        var lowered = original
        lowered.rlim_cur = min(original.rlim_cur, 256)
        setrlimit(RLIMIT_NOFILE, &lowered)
        let result = Result { try SafeRemoval.delete("n", inDirectory: tree.root) }
        setrlimit(RLIMIT_NOFILE, &original)

        #expect(throws: Never.self) { try result.get() }
        #expect(!onDisk(tree.path("n")))
    }

    @Test("A deep tree is removed on a thread with a small stack: the walk doesn't recurse")
    func deepTreeOnSmallStack() throws {
        let tree = try TempTree()
        let root = tree.root
        // Every change deep in a tree costs time in proportion to its depth on APFS, so a 10,000-level tree would
        // take minutes. A small stack shows the same thing: a walk that used a frame per level would overflow it.
        SafeRemovalTests.nest(300, in: root)
        let failure = Mutex<String?>("not finished")
        let thread = Thread {
            do {
                try SafeRemoval.delete("n", inDirectory: root)
                failure.withLock { $0 = nil }
            } catch {
                failure.withLock { $0 = error.localizedDescription }
            }
        }
        thread.stackSize = 32 * 1024
        thread.start()
        while !thread.isFinished { usleep(1_000) }
        #expect(failure.withLock { $0 } == nil)
        #expect(!onDisk(tree.path("n")))
    }

    @Test("An entry that can't be removed doesn't stop the rest; the error names it and counts the others")
    func continuesPastFailures() throws {
        let tree = try TempTree()
        for name in ["a", "b", "c", "d", "e"] { try tree.file("item/\(name)", bytes: 100) }
        try tree.file("item/sub/x", bytes: 100)
        try tree.file("item/sub/locked", bytes: 100)
        try tree.file("item/sub/y", bytes: 100)
        try tree.file("item/z/w", bytes: 100)
        let locked = [tree.path("item/c"), tree.path("item/sub/locked")]
        for path in locked { #expect(chflags(path, UInt32(UF_IMMUTABLE)) == 0) }
        defer { for path in locked { chflags(path, 0) } }

        var thrown: Error?
        do {
            try SafeRemoval.delete("item", inDirectory: tree.root)
        } catch {
            thrown = error
        }

        let incomplete = try #require(thrown as? SafeRemoval.Incomplete)
        #expect(incomplete.count == 2)
        #expect(locked.contains(incomplete.path))
        #expect(incomplete.localizedDescription.contains("(and 1 more)"))
        #expect(Set(names(in: tree.path("item"))) == ["c", "sub"])
        #expect(names(in: tree.path("item/sub")) == ["locked"])
    }

    /// Creates `n/n/n/…` `depth` levels deep inside `root`. Built from the bottom up by moving each chain into a
    /// new top folder, so no step works at depth.
    static func nest(_ depth: Int, in root: String) {
        let fd = open(root, O_RDONLY | O_DIRECTORY)
        defer { close(fd) }
        mkdirat(fd, "n", 0o755)
        for _ in 1..<depth {
            mkdirat(fd, "next", 0o755)
            renameat(fd, "n", fd, "next/n")
            renameat(fd, "next", fd, "n")
        }
    }

    @Test("Files, symlinks and nested folders are removed; a symlink's target stays")
    func mixedContents() throws {
        let tree = try TempTree()
        try tree.file("item/a/b/c/file", bytes: 2_000)
        try tree.file("item/top", bytes: 100)
        try tree.file("outside/keep", bytes: 100)
        try FileManager.default.createSymbolicLink(atPath: tree.path("item/a/link"), withDestinationPath: tree.path("outside"))
        try FileManager.default.createSymbolicLink(atPath: tree.path("item/filelink"), withDestinationPath: tree.path("outside/keep"))
        try tree.file("single", bytes: 100)

        try SafeRemoval.delete("item", inDirectory: tree.root)
        try SafeRemoval.delete("single", inDirectory: tree.root)
        #expect(!onDisk(tree.path("item")))
        #expect(!onDisk(tree.path("single")))
        #expect(onDisk(tree.path("outside/keep")))
    }
}
