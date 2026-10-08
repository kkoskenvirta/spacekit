import Foundation
import Testing

@testable import SpaceKitCore

/// A mutation reaches hard links through an index of the folders holding them, so these cases change where a link
/// lives (move, arrival, splice) and then take it away: the second step only finds the link if the index followed.
extension TreeConsistencyTests {
    func expectSteps(_ tree: TempTree, _ steps: [(String, () throws -> [Removal])]) throws {
        let scanned = try scan(tree.root)
        for (name, step) in steps {
            for removal in try step() { removal.apply(to: scanned) }
            try expectMatchesRescan(scanned, root: tree.root, minFileSize: 0, name)
        }
    }

    func linkedFixture() throws -> TempTree {
        let tree = try TempTree()
        try tree.file("a/inner/data.bin", bytes: 120_000)
        try tree.link("a/inner/data.bin", "b/data.bin")
        try tree.link("a/inner/data.bin", "c/data.bin")
        try tree.directory(".Trash")
        return tree
    }

    @Test("A trashed hard link is found again when it's deleted from the Trash")
    func hardLinkMovedThenDeleted() throws {
        let tree = try linkedFixture()
        let fm = FileManager.default
        try expectSteps(tree, [
            ("trash the owner", {
                let destination = try #require(try sandboxTrash(home: tree.root)(tree.path("a/inner/data.bin")))
                return [Removal(path: tree.path("a/inner/data.bin"), kind: .file, bytes: 0, trashedTo: destination)]
            }),
            ("delete it from the Trash", {
                try fm.removeItem(atPath: tree.path(".Trash/data.bin"))
                return [Removal(path: tree.path(".Trash/data.bin"), kind: .file, bytes: 0)]
            }),
            ("delete the next owner", {
                try fm.removeItem(atPath: tree.path("b/data.bin"))
                return [Removal(path: tree.path("b/data.bin"), kind: .file, bytes: 0)]
            }),
        ])
    }

    @Test("Deleting a folder takes the hard links nested deep inside it")
    func hardLinkNestedFolder() throws {
        let tree = try linkedFixture()
        let fm = FileManager.default
        try expectSteps(tree, [
            ("trash the outer folder", {
                let destination = try #require(try sandboxTrash(home: tree.root)(tree.path("a")))
                return [Removal(path: tree.path("a"), kind: .directory, bytes: 0, trashedTo: destination)]
            }),
            ("delete the trashed folder", {
                try fm.removeItem(atPath: tree.path(".Trash/a"))
                return [Removal(path: tree.path(".Trash/a"), kind: .directory, bytes: 0)]
            }),
        ])
    }

    @Test("A hard link that arrived in the Trash with loose files is found when it's deleted")
    func hardLinkArrivedThenDeleted() throws {
        let tree = try linkedFixture()
        let fm = FileManager.default
        try expectSteps(tree, [
            ("trash the loose files of a/inner", {
                let destination = try #require(try sandboxTrash(home: tree.root)(tree.path("a/inner/data.bin")))
                return [Removal(path: tree.path("a/inner"), kind: .looseFiles, bytes: 0, trashedFiles: [destination])]
            }),
            ("delete the arrival", {
                try fm.removeItem(atPath: tree.path(".Trash/data.bin"))
                return [Removal(path: tree.path(".Trash/data.bin"), kind: .file, bytes: 0)]
            }),
            ("delete the loose files of b", {
                try fm.removeItem(atPath: tree.path("b/data.bin"))
                return [Removal(path: tree.path("b"), kind: .looseFiles, bytes: 0)]
            }),
        ])
    }

    @Test("Hard links taken in by a splice are found by later removals")
    func hardLinkSplicedThenDeleted() throws {
        let tree = try linkedFixture()
        let scanned = try scan(tree.root)
        scanned.splice(try scan(tree.path("b")), at: tree.path("b"))
        try expectMatchesRescan(scanned, root: tree.root, minFileSize: 0, "splice b")
        for relative in ["a/inner/data.bin", "b/data.bin"] {
            try FileManager.default.removeItem(atPath: tree.path(relative))
            scanned.applyRemoval(of: tree.path(relative))
            try expectMatchesRescan(scanned, root: tree.root, minFileSize: 0, "delete \(relative)")
        }
        scanned.splice(try scan(tree.path("c")), at: tree.path("c"))
        try expectMatchesRescan(scanned, root: tree.root, minFileSize: 0, "splice c")
    }
}

/// An in-memory tree of `groups` files of `size` bytes, each with one link in every top folder `l0`, `l1`, …;
/// `l0` holds the bytes. Built without the disk because a fixture this size takes seconds to create.
func linkedTree(groups: Int, links: Int, perFolder: Int, size: UInt64 = 4_096) -> ScanTree {
    let root = DirNode(name: "/linked", parent: nil)
    var folders: [[DirNode]] = []
    for k in 0..<links {
        let top = DirNode(name: "l\(k)", parent: root)
        let leaves = (0..<groups / perFolder).map { DirNode(name: "s\($0)", parent: top) }
        for leaf in leaves {
            leaf.otherFilesCount = UInt32(perFolder)
            leaf.otherFilesSize = k == 0 ? UInt64(perFolder) * size : 0
            leaf.directFileCount = leaf.otherFilesCount
            leaf.directFileSize = leaf.otherFilesSize
        }
        top.children = leaves
        root.children.append(top)
        folders.append(leaves)
    }
    Scanner.aggregate(root)
    var table: [HardLinkKey: HardLinkGroup] = [:]
    for g in 0..<groups {
        let name = "f\(g % perFolder)"
        let members = (0..<links).map { HardLink(node: folders[$0][g / perFolder], name: name, hasBytes: $0 == 0) }
        table[HardLinkKey(device: 1, inode: UInt64(g))] = HardLinkGroup(size: size, modified: 0, links: members)
    }
    let stats = ScanStats(files: 0, directories: 0, errors: 0, duration: 0, cancelled: false)
    return ScanTree(
        root: root, roots: ["/linked"], stats: stats, options: ScanOptions(), capacity: nil, scanStarted: Date(), hardLinks: table)
}

@Suite("Hard-link scale")
struct HardLinkScaleTests {
    @Test("A removal's cost doesn't grow with the number of hard-linked files elsewhere in the tree")
    func removalsScale() throws {
        let tree = linkedTree(groups: 20_000, links: 5, perFolder: 100)
        let total = tree.root.size
        let files: [(Int, Int, Int)] = (0..<500).map { n in (n % 5, n * 7 % 200, n / 5) }
        let folders: [(Int, Int)] = (0..<50).map { n in (n % 5, 100 + n) }
        let started = ContinuousClock.now
        for (k, j, i) in files { tree.applyRemoval(of: "/linked/l\(k)/s\(j)/f\(i)", bytes: 4_096) }
        for (k, j) in folders { tree.applyRemoval(of: "/linked/l\(k)/s\(j)") }
        let elapsed = ContinuousClock.now - started
        let filesInFolders = files.filter { file in folders.contains { $0 == (file.0, file.1) } }.count
        // Debug build: scanning every group per update took ~19 s here; the index takes ~0.15 s.
        #expect(elapsed < .seconds(2), "550 updates took \(elapsed)")
        #expect(tree.inconsistencies().isEmpty, "\(tree.inconsistencies())")
        #expect(tree.root.size == total, "every file keeps a link, so no bytes go")
        #expect(tree.root.fileCount == UInt64(100_000 - (500 - filesInFolders) - 50 * 100))
    }

    @Test("Removing every link of a file takes its bytes out, whichever link held them")
    func lastLinkTakesBytes() {
        let tree = linkedTree(groups: 200, links: 3, perFolder: 100)
        let total = tree.root.size
        for k in [1, 0, 2] { tree.applyRemoval(of: "/linked/l\(k)/s0/f7", bytes: 4_096) }
        #expect(tree.root.size == total - 4_096)
        #expect(tree.node(at: "/linked/l1/s0")?.size == 0)
        #expect(tree.node(at: "/linked/l0/s0")?.size == 99 * 4_096)
        #expect(tree.inconsistencies().isEmpty, "\(tree.inconsistencies())")
    }
}
