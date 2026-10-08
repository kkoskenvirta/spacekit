import Foundation
import Testing

@testable import SpaceKitCore

/// Proves that in-place tree updates match what a full rescan of the disk would say.
@Suite("Tree consistency")
struct TreeConsistencyTests {
    /// Sizes of every folder in a tree, keyed by path relative to `root`.
    func folderSizes(_ tree: ScanTree, root: String) -> [String: UInt64] {
        var sizes: [String: UInt64] = [:]
        tree.root.forEachDescendant { node in
            sizes[String(node.path.dropFirst(root.count))] = node.size
            return true
        }
        return sizes
    }

    func expectMatchesRescan(_ tree: ScanTree, root: String, minFileSize: UInt64, _ step: String) throws {
        let fresh = try scan(root, minFileSize: minFileSize)
        #expect(tree.inconsistencies().isEmpty, "\(step): \(tree.inconsistencies())")
        #expect(tree.root.size == fresh.root.size, "\(step): total \(tree.root.size) vs rescan \(fresh.root.size)")
        #expect(tree.root.fileCount == fresh.root.fileCount, "\(step): files \(tree.root.fileCount) vs \(fresh.root.fileCount)")
        let mine = folderSizes(tree, root: root)
        let theirs = folderSizes(fresh, root: root)
        for (path, size) in theirs where mine[path] != size {
            Issue.record("\(step): \(path) is \(mine[path].map(String.init) ?? "missing") but rescan says \(size)")
        }
        for path in mine.keys where theirs[path] == nil {
            Issue.record("\(step): \(path) is still in the tree but gone from disk")
        }
    }

    @Test("Random deletes and moves to the Trash always match a full rescan", arguments: [UInt64(0), 50_000])
    func randomOperations(minFileSize: UInt64) throws {
        var rng = SeededRandom(seed: 42 &+ minFileSize)
        let tree = try TempTree()
        try tree.directory(".Trash")
        let trash = sandboxTrash(home: tree.root)
        // A random project-like hierarchy with large and small files.
        var folders = [""]
        for index in 0..<30 {
            let parent = folders[Int(rng.next() % UInt64(folders.count))]
            let folder = (parent.isEmpty ? "" : parent + "/") + "d\(index)"
            folders.append(folder)
            for file in 0..<Int(rng.next() % 4) {
                let size = rng.next() % 2 == 0 ? 4_000 + Int(rng.next() % 20_000) : 60_000 + Int(rng.next() % 200_000)
                try tree.file("\(folder)/f\(file).bin", bytes: size)
            }
        }
        // Hard links across folders: the tree credits each file's bytes to one of its links.
        let fm = FileManager.default
        for index in 0..<10 {
            let files: [String] = (fm.enumerator(atPath: tree.root)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".bin") }
            guard !files.isEmpty else { break }
            let source = files[Int(rng.next() % UInt64(files.count))]
            let folder = folders[Int(rng.next() % UInt64(folders.count))]
            try tree.link(source, (folder.isEmpty ? "" : folder + "/") + "h\(index).bin")
        }
        let scanned = try scan(tree.root, minFileSize: minFileSize)
        try expectMatchesRescan(scanned, root: tree.root, minFileSize: minFileSize, "initial")

        for step in 0..<40 {
            // Pick a random existing item outside the Trash.
            let candidates = (fm.enumerator(atPath: tree.root)?.allObjects as? [String] ?? [])
                .filter { !$0.hasPrefix(".Trash") }
            guard !candidates.isEmpty else { break }
            let relative = candidates[Int(rng.next() % UInt64(candidates.count))]
            let path = tree.path(relative)
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDirectory)
            var st = stat()
            lstat(path, &st)
            let fileBytes = UInt64(st.st_blocks) * 512
            let operation = rng.next() % 3

            let removal: Removal
            if operation == 0 && isDirectory.boolValue {
                let toTrash = rng.next() % 2 == 0
                var bytes: UInt64 = 0
                var trashed: [String] = []
                for name in try fm.contentsOfDirectory(atPath: path) {
                    var child = stat()
                    lstat(path + "/" + name, &child)
                    guard (child.st_mode & S_IFMT) != S_IFDIR else { continue }
                    bytes += UInt64(child.st_blocks) * 512
                    if toTrash {
                        trashed.append(try #require(try trash(path + "/" + name)))
                    } else {
                        try fm.removeItem(atPath: path + "/" + name)
                    }
                }
                removal = Removal(path: path, kind: .looseFiles, bytes: bytes, trashedFiles: trashed)
            } else if operation == 1 {
                let bytes = isDirectory.boolValue ? (scanned.node(at: path)?.size ?? 0) : fileBytes
                let destination = try #require(try trash(path))
                removal = Removal(path: path, kind: isDirectory.boolValue ? .directory : .file, bytes: bytes, trashedTo: destination)
            } else {
                let bytes = isDirectory.boolValue ? (scanned.node(at: path)?.size ?? 0) : fileBytes
                try fm.removeItem(atPath: path)
                removal = Removal(path: path, kind: isDirectory.boolValue ? .directory : .file, bytes: bytes)
            }
            removal.apply(to: scanned)
            try expectMatchesRescan(scanned, root: tree.root, minFileSize: minFileSize, "step \(step) (\(operation) \(relative))")
        }

        // Emptying the Trash outside SpaceKit: resync just that folder.
        for name in try fm.contentsOfDirectory(atPath: tree.path(".Trash")) { try fm.removeItem(atPath: tree.path(".Trash/\(name)")) }
        scanned.splice(try scan(tree.path(".Trash"), minFileSize: minFileSize), at: tree.path(".Trash"))
        try expectMatchesRescan(scanned, root: tree.root, minFileSize: minFileSize, "after emptying the Trash")
    }

    @Test("Moving to the Trash keeps the total and shows the item in the Trash")
    func moveToTrash() throws {
        let tree = try TempTree()
        try tree.file("Library/Caches/app/blob.bin", bytes: 300_000)
        try tree.directory(".Trash")
        let scanned = try scan(tree.root)
        let total = scanned.root.size
        try FileManager.default.moveItem(atPath: tree.path("Library/Caches/app"), toPath: tree.path(".Trash/app"))
        #expect(scanned.applyMove(of: tree.path("Library/Caches/app"), to: tree.path(".Trash/app")))
        #expect(scanned.root.size == total, "moving to the Trash frees nothing yet")
        #expect(scanned.node(at: tree.path(".Trash/app"))?.size == tree.allocated(".Trash/app/blob.bin"))
        #expect(scanned.node(at: tree.path("Library/Caches"))?.size == 0)
        #expect(scanned.node(at: tree.path(".Trash/app"))?.depth == 2)
        #expect(scanned.inconsistencies().isEmpty)
    }

    @Test("Small files (folded into a folder total) are removed with a size hint")
    func smallFiles() throws {
        let tree = try TempTree()
        try tree.file("cache/tiny.tmp", bytes: 5_000)
        try tree.file("cache/big.bin", bytes: 2_000_000)
        let scanned = try scan(tree.root, minFileSize: 1_000_000)
        let tiny = tree.allocated("cache/tiny.tmp")
        try FileManager.default.removeItem(atPath: tree.path("cache/tiny.tmp"))
        #expect(scanned.applyRemoval(of: tree.path("cache/tiny.tmp"), bytes: tiny) == tiny)
        #expect(scanned.node(at: tree.path("cache"))?.otherFilesCount == 0)
        #expect(scanned.root.size == tree.allocated("cache/big.bin"))
        #expect(scanned.inconsistencies().isEmpty)
    }

    @Test("Loose-file removal keeps the files the cleanup skipped", arguments: [UInt64(0), 50_000])
    func partialLooseFiles(minFileSize: UInt64) throws {
        let tree = try TempTree()
        try tree.file("cache/big.bin", bytes: 200_000)
        try tree.file("cache/kept-big.bin", bytes: 150_000)
        try tree.file("cache/small.tmp", bytes: 5_000)
        try tree.file("cache/kept-small.tmp", bytes: 8_000)
        try tree.file("cache/sub/inner.bin", bytes: 100_000)
        let scanned = try scan(tree.root, minFileSize: minFileSize)
        let removed = tree.allocated("cache/big.bin") + tree.allocated("cache/small.tmp")
        try FileManager.default.removeItem(atPath: tree.path("cache/big.bin"))
        try FileManager.default.removeItem(atPath: tree.path("cache/small.tmp"))

        let taken = scanned.applyRemoval(of: tree.path("cache"), looseFilesOnly: true)
        #expect(taken == removed)
        try expectMatchesRescan(scanned, root: tree.root, minFileSize: minFileSize, "partial loose files")
        #expect(scanned.node(at: tree.path("cache"))?.directFileCount == 2)
    }

    @Test("Loose files moved to the Trash reappear in the Trash", arguments: [UInt64(0), 50_000])
    func trashedLooseFiles(minFileSize: UInt64) throws {
        let tree = try TempTree()
        try tree.file("cache/big.bin", bytes: 200_000)
        try tree.file("cache/small.tmp", bytes: 5_000)
        try tree.file("cache/kept.bin", bytes: 150_000)
        try tree.file("cache/linked.bin", bytes: 90_000)
        try tree.link("cache/linked.bin", "docs/linked.bin")
        try tree.file("cache/sub/inner.bin", bytes: 100_000)
        try tree.file(".Trash/big.bin", bytes: 4_000)
        let scanned = try scan(tree.root, minFileSize: minFileSize)
        let moves = [("big.bin", "big 2.bin"), ("small.tmp", "small.tmp"), ("linked.bin", "linked.bin")]
        var bytes: UInt64 = 0
        for (name, destination) in moves {
            bytes += tree.allocated("cache/\(name)")
            try FileManager.default.moveItem(atPath: tree.path("cache/\(name)"), toPath: tree.path(".Trash/\(destination)"))
        }

        var report = CleanupReport(dryRun: false)
        report.items = [(CleanupItem(path: tree.path("cache"), kind: .looseFiles, size: bytes), .removed(bytes: bytes, trashedTo: nil))]
        report.trashedLooseFiles = [tree.path("cache"): moves.map { tree.path(".Trash/\($0.1)") }]
        let removals = Removal.from(report)
        #expect(removals.first?.trashedFiles == moves.map { tree.path(".Trash/\($0.1)") })
        for removal in removals { removal.apply(to: scanned) }
        try expectMatchesRescan(scanned, root: tree.root, minFileSize: minFileSize, "trashed loose files")
        #expect(scanned.node(at: tree.path(".Trash"))?.directFileCount == 4)
        #expect(scanned.node(at: tree.path("cache"))?.directFileCount == 1)
    }

    @Test("A fresh scan of a folder replaces its old contents")
    func splice() throws {
        let tree = try TempTree()
        try tree.file("a/old.bin", bytes: 400_000)
        try tree.file("b/keep.bin", bytes: 100_000)
        let scanned = try scan(tree.root)
        try FileManager.default.removeItem(atPath: tree.path("a/old.bin"))
        try tree.file("a/new/fresh.bin", bytes: 200_000)
        scanned.splice(try scan(tree.path("a")), at: tree.path("a"))
        try expectMatchesRescan(scanned, root: tree.root, minFileSize: 0, "splice")
        #expect(scanned.node(at: tree.path("a/new"))?.depth == 2)
    }
}

@Suite("Capacity and reporting")
struct CapacityReportingTests {
    @Test("Available includes purgeable space; used excludes it (like Finder)")
    func capacitySemantics() {
        // The situation on a Mac with local Time Machine snapshots after deleting 64 GB.
        let capacity = VolumeCapacity(
            name: "Macintosh HD", mountPoint: "/", total: 494_000_000_000,
            freeNow: 13_900_000_000, available: 77_800_000_000)
        #expect(capacity.purgeable == 63_900_000_000)
        #expect(capacity.used == 494_000_000_000 - 77_800_000_000)
        #expect(capacity.used + capacity.available == capacity.total)
        // Inconsistent inputs are clamped, never negative.
        let odd = VolumeCapacity(name: "x", mountPoint: "/", total: 100, freeNow: 50, available: 20)
        #expect(odd.available == 50 && odd.purgeable == 0 && odd.used == 50)
    }

    @Test("Live capacity is read fresh and is internally consistent")
    func liveCapacity() throws {
        let capacity = try #require(VolumeCapacity.of(path: "/"))
        #expect(capacity.total > 0)
        #expect(capacity.freeNow <= capacity.available)
        #expect(capacity.used + capacity.available == capacity.total)
    }

    @Test("Reports separate trashed bytes from released bytes")
    func trashedVersusDeleted() {
        var report = CleanupReport(dryRun: false)
        report.items = [
            (CleanupItem(path: "/tmp/a", size: 100), .removed(bytes: 100, trashedTo: "/Users/x/.Trash/a")),
            (CleanupItem(path: "/tmp/b", size: 50), .removed(bytes: 50, trashedTo: nil)),
            (CleanupItem(path: "/tmp/c", size: 70), .skipped(reason: "nope", kind: .refused)),
        ]
        #expect(report.freedBytes == 150)
        #expect(report.trashedBytes == 100)
        #expect(report.deletedBytes == 50)
        let removals = Removal.from(report)
        #expect(removals.map(\.path) == ["/tmp/a", "/tmp/b"])
        #expect(removals.first?.trashedTo == "/Users/x/.Trash/a")
    }
}

/// Deterministic random numbers so failures reproduce.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var x = state
        x ^= x >> 33
        x = x &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 33
        return x
    }
}
