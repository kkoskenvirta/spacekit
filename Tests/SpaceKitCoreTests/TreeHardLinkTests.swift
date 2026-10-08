import Foundation
import Testing

@testable import SpaceKitCore

extension TempTree {
    /// Adds another name for an existing file (a hard link).
    func link(_ existing: String, _ relative: String) throws {
        try FileManager.default.createDirectory(atPath: PathUtil.parent(path(relative)), withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: path(existing), toPath: path(relative))
    }
}

/// The scan credits a multiply-linked file's bytes to the link whose folder sorts first (then name), so taking that
/// link away has to hand the bytes to a surviving link, the one a rescan would credit.
extension TreeConsistencyTests {
    /// Each case gets a fresh tree: `cache/` holds the owning links, `docs/` and `zeta/` the others. `Bin/.Trash`
    /// sorts before all of them and `trash/.Trash` between `docs` and `zeta`, so moves can change the owner.
    func hardLinkCase(minFileSize: UInt64, _ name: String, _ change: (TempTree) throws -> [Removal]) throws {
        let tree = try TempTree()
        try tree.file("cache/data.bin", bytes: 120_000)
        try tree.file("cache/tiny.bin", bytes: 8_000)
        try tree.file("cache/plain.bin", bytes: 70_000)
        for folder in ["docs", "zeta"] {
            try tree.link("cache/data.bin", "\(folder)/data.bin")
            try tree.link("cache/tiny.bin", "\(folder)/tiny.bin")
        }
        try tree.directory("Bin/.Trash")
        try tree.directory("trash/.Trash")
        let scanned = try scan(tree.root, minFileSize: minFileSize)
        try expectMatchesRescan(scanned, root: tree.root, minFileSize: minFileSize, "\(name): initial")
        for removal in try change(tree) { removal.apply(to: scanned) }
        try expectMatchesRescan(scanned, root: tree.root, minFileSize: minFileSize, name)
    }

    @Test("Removing or trashing a hard link hands its bytes to the link a rescan would credit", arguments: [UInt64(0), 50_000])
    func hardLinks(minFileSize: UInt64) throws {
        let fm = FileManager.default
        for file in ["data.bin", "tiny.bin"] {
            try hardLinkCase(minFileSize: minFileSize, "delete owner \(file)") { tree in
                let bytes = tree.allocated("cache/\(file)")
                try fm.removeItem(atPath: tree.path("cache/\(file)"))
                return [Removal(path: tree.path("cache/\(file)"), kind: .file, bytes: bytes)]
            }
            try hardLinkCase(minFileSize: minFileSize, "delete other \(file)") { tree in
                let bytes = tree.allocated("docs/\(file)")
                try fm.removeItem(atPath: tree.path("docs/\(file)"))
                return [Removal(path: tree.path("docs/\(file)"), kind: .file, bytes: bytes)]
            }
            try hardLinkCase(minFileSize: minFileSize, "trash owner \(file) behind the others") { tree in
                let bytes = tree.allocated("cache/\(file)")
                try fm.moveItem(atPath: tree.path("cache/\(file)"), toPath: tree.path("trash/.Trash/\(file)"))
                return [Removal(path: tree.path("cache/\(file)"), kind: .file, bytes: bytes, trashedTo: tree.path("trash/.Trash/\(file)"))]
            }
            try hardLinkCase(minFileSize: minFileSize, "trash other \(file) ahead of the owner") { tree in
                let bytes = tree.allocated("zeta/\(file)")
                try fm.moveItem(atPath: tree.path("zeta/\(file)"), toPath: tree.path("Bin/.Trash/\(file)"))
                return [Removal(path: tree.path("zeta/\(file)"), kind: .file, bytes: bytes, trashedTo: tree.path("Bin/.Trash/\(file)"))]
            }
        }
        try hardLinkCase(minFileSize: minFileSize, "delete the owner's folder") { tree in
            try fm.removeItem(atPath: tree.path("cache"))
            return [Removal(path: tree.path("cache"), kind: .directory, bytes: 0)]
        }
        try hardLinkCase(minFileSize: minFileSize, "trash the owner's folder behind the others") { tree in
            try fm.moveItem(atPath: tree.path("cache"), toPath: tree.path("trash/.Trash/cache"))
            return [Removal(path: tree.path("cache"), kind: .directory, bytes: 0, trashedTo: tree.path("trash/.Trash/cache"))]
        }
        try hardLinkCase(minFileSize: minFileSize, "trash another folder ahead of the owner") { tree in
            try fm.moveItem(atPath: tree.path("zeta"), toPath: tree.path("Bin/.Trash/zeta"))
            return [Removal(path: tree.path("zeta"), kind: .directory, bytes: 0, trashedTo: tree.path("Bin/.Trash/zeta"))]
        }
        try hardLinkCase(minFileSize: minFileSize, "delete the owner's loose files") { tree in
            var bytes: UInt64 = 0
            for file in ["data.bin", "tiny.bin", "plain.bin"] {
                bytes += tree.allocated("cache/\(file)")
                try fm.removeItem(atPath: tree.path("cache/\(file)"))
            }
            return [Removal(path: tree.path("cache"), kind: .looseFiles, bytes: bytes)]
        }
        try hardLinkCase(minFileSize: minFileSize, "delete every link") { tree in
            let bytes = tree.allocated("cache/data.bin")
            for folder in ["cache", "docs", "zeta"] { try fm.removeItem(atPath: tree.path("\(folder)/data.bin")) }
            return ["cache", "docs", "zeta"].map { Removal(path: tree.path("\($0)/data.bin"), kind: .file, bytes: bytes) }
        }
    }

    @Test("Emptying a Trash that held the owning link hands the bytes back to the survivor")
    func hardLinkSplice() throws {
        let tree = try TempTree()
        try tree.file("cache/data.bin", bytes: 120_000)
        try tree.link("cache/data.bin", "docs/data.bin")
        try tree.directory(".Trash")
        let scanned = try scan(tree.root)
        try FileManager.default.moveItem(atPath: tree.path("cache"), toPath: tree.path(".Trash/cache"))
        scanned.applyMove(of: tree.path("cache"), to: tree.path(".Trash/cache"))
        try expectMatchesRescan(scanned, root: tree.root, minFileSize: 0, "trashed")
        try FileManager.default.removeItem(atPath: tree.path(".Trash/cache"))
        scanned.splice(try scan(tree.path(".Trash")), at: tree.path(".Trash"))
        try expectMatchesRescan(scanned, root: tree.root, minFileSize: 0, "emptied")
    }
}
