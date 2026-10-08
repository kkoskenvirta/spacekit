import CoreGraphics
import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Scanner")
struct ScannerTests {
    @Test("Totals match allocated sizes")
    func totals() throws {
        let tree = try TempTree()
        try tree.file("a/one.bin", bytes: 300_000)
        try tree.file("a/b/two.bin", bytes: 2_000_000)
        try tree.file("c/three.bin", bytes: 50_000)
        let expected = tree.allocated("a/one.bin") + tree.allocated("a/b/two.bin") + tree.allocated("c/three.bin")

        let result = try scan(tree.root)
        #expect(result.root.size == expected)
        #expect(result.root.fileCount == 3)
        #expect(result.root.dirCount == 3)
        #expect(result.node(at: tree.path("a"))?.size == tree.allocated("a/one.bin") + tree.allocated("a/b/two.bin"))
        #expect(result.stats.errors == 0)
    }

    @Test("Small files are folded but still counted")
    func folding() throws {
        let tree = try TempTree()
        try tree.file("big.bin", bytes: 3_000_000)
        for index in 0..<20 { try tree.file("small-\(index).txt", bytes: 1000) }
        let result = try scan(tree.root, minFileSize: 1_000_000)
        #expect(result.root.files.map(\.name) == ["big.bin"])
        #expect(result.root.otherFilesCount == 20)
        #expect(result.root.size == result.root.directFileSize)
        let items = result.root.items
        #expect(items.count == 2)
        #expect(items.first?.name == "big.bin")
    }

    @Test("Hard links are counted once")
    func hardLinks() throws {
        let tree = try TempTree()
        let original = try tree.file("store/blob", bytes: 1_000_000)
        try tree.directory("project")
        try FileManager.default.linkItem(atPath: original, toPath: tree.path("project/linked"))
        let result = try scan(tree.root)
        #expect(result.root.size == tree.allocated("store/blob"))
    }

    @Test("Hard-linked bytes go to the link whose folder sorts first, whatever the thread timing", arguments: [UInt64(0), 2_000_000])
    func hardLinkAttribution(minFileSize: UInt64) throws {
        let tree = try TempTree()
        let original = try tree.file("store/blob", bytes: 1_000_000)
        for folder in ["z-last", "a-first", "m-middle"] {
            try tree.directory(folder)
            try FileManager.default.linkItem(atPath: original, toPath: tree.path("\(folder)/linked"))
        }
        for index in 0..<40 { try tree.file("filler/d\(index)/f.bin", bytes: 4_000) }
        let bytes = tree.allocated("store/blob")
        for threads in [1, 2, 4, 8, 1, 4, 8] {
            let result = try scan(tree.root, minFileSize: minFileSize) { $0.threads = threads }
            #expect(result.node(at: tree.path("a-first"))?.size == bytes, "threads \(threads)")
            for folder in ["store", "m-middle", "z-last"] {
                #expect(result.node(at: tree.path(folder))?.size == 0, "\(folder), threads \(threads)")
                #expect(result.node(at: tree.path(folder))?.directFileCount == 1)
            }
            let first = try #require(result.node(at: tree.path("a-first")))
            #expect(first.files.map(\.name) == (minFileSize == 0 ? ["linked"] : []))
            #expect(result.inconsistencies().isEmpty, "\(result.inconsistencies())")
        }
    }

    @Test("Symlinks are not followed")
    func symlinks() throws {
        let tree = try TempTree()
        try tree.file("target/data.bin", bytes: 1_000_000)
        try FileManager.default.createSymbolicLink(atPath: tree.path("link"), withDestinationPath: tree.path("target"))
        let result = try scan(tree.root)
        #expect(result.root.size < tree.allocated("target/data.bin") * 2)
        #expect(result.node(at: tree.path("link")) == nil)
    }

    @Test("Marker files are recorded per directory")
    func markers() throws {
        let tree = try TempTree()
        try tree.file("app/package.json", bytes: 10)
        try tree.file("app/node_modules/x/index.js", bytes: 10)
        try tree.directory("repo/.git")
        let result = try scan(tree.root, markers: ["package.json"])
        let app = try #require(result.node(at: tree.path("app")))
        #expect(result.markers.contains("package.json", in: app.markers))
        #expect(!result.markers.contains("package.json", in: result.root.markers))
        #expect(result.markers.contains("package.json", in: result.root.subtreeMarkers))
        let repo = try #require(result.node(at: tree.path("repo")))
        #expect(result.markers.contains(".git", in: repo.markers))
    }

    @Test("Excluded paths are skipped")
    func excludes() throws {
        let tree = try TempTree()
        try tree.file("keep/a.bin", bytes: 100_000)
        try tree.file("skip/b.bin", bytes: 100_000)
        let result = try scan(tree.root) { $0.exclude = [tree.path("skip")] }
        #expect(result.node(at: tree.path("skip"))?.flags.contains(.excluded) == true)
        #expect(result.root.size == tree.allocated("keep/a.bin"))
    }

    @Test("Multi-root scans don't double count nested roots")
    func multiRoot() throws {
        let tree = try TempTree()
        try tree.file("x/a.bin", bytes: 100_000)
        try tree.file("y/b.bin", bytes: 100_000)
        var options = ScanOptions()
        options.minFileSize = 0
        let result = try Scanner(options: options).scan(roots: [tree.path("x"), tree.path("y"), tree.path("x")])
        #expect(result.isMultiRoot)
        #expect(result.root.children.count == 2)
        #expect(result.node(at: tree.path("y/")) != nil)
        #expect(result.root.size == tree.allocated("x/a.bin") + tree.allocated("y/b.bin"))
    }

    @Test("Node paths round-trip")
    func paths() throws {
        let tree = try TempTree()
        try tree.file("one/two/three/file.bin", bytes: 10)
        let result = try scan(tree.root)
        let node = try #require(result.node(at: tree.path("one/two/three")))
        #expect(node.path == tree.path("one/two/three"))
        #expect(node.ancestors.count == 3)
    }

    @Test("Removing from the tree updates every ancestor")
    func applyRemoval() throws {
        let tree = try TempTree()
        try tree.file("a/b/big.bin", bytes: 2_000_000)
        try tree.file("a/keep.bin", bytes: 2_000_000)
        let result = try scan(tree.root)
        let before = result.root.size
        let removed = result.applyRemoval(of: tree.path("a/b"))
        #expect(removed == tree.allocated("a/b/big.bin"))
        #expect(result.root.size == before - removed)
        #expect(result.node(at: tree.path("a/b")) == nil)
    }

    @Test("Cancelling stops the scan")
    func cancellation() throws {
        let tree = try TempTree()
        for index in 0..<50 { try tree.file("d\(index)/f.bin", bytes: 10) }
        let progress = ScanProgress()
        progress.cancel()
        let result = try Scanner().scan(tree.root, progress: progress)
        #expect(result.stats.cancelled)
    }

    @Test("Missing paths throw")
    func missing() {
        #expect(throws: ScanError.self) { try Scanner().scan("/definitely/not/here") }
    }
}

@Suite("Layout")
struct LayoutTests {
    @Test("Squarified cells are proportional and stay inside the bounds")
    func squarify() {
        let weights: [Double] = [500, 300, 120, 50, 20, 7, 3]
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
        let rects = Treemap.squarify(weights, in: bounds)
        let total = weights.reduce(0, +)
        for (weight, rect) in zip(weights, rects) {
            let expected = Double(bounds.width * bounds.height) * weight / total
            #expect(abs(Double(rect.width * rect.height) - expected) / expected < 0.01)
            #expect(bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect))
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.5)
            }
        }
    }

    @Test("Zero and empty weights are handled")
    func degenerate() {
        #expect(Treemap.squarify([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        let rects = Treemap.squarify([0, 5], in: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(rects[0] == .zero)
        #expect(rects[1].width * rects[1].height == 100)
    }

    @Test("Sunburst arcs of the first ring cover the full circle")
    func sunburst() throws {
        let tree = try TempTree()
        try tree.file("a/x.bin", bytes: 400_000)
        try tree.file("b/y.bin", bytes: 300_000)
        try tree.file("c.bin", bytes: 200_000)
        let result = try scan(tree.root)
        let arcs = Sunburst.layout(result.root)
        let ring1 = arcs.filter { $0.ring == 1 }
        let sweep = ring1.reduce(0) { $0 + $1.sweep }
        #expect(abs(sweep - 2 * .pi) < 0.001)
        let hit = Sunburst.hitTest(arcs, at: CGPoint(x: 100, y: 40), center: CGPoint(x: 100, y: 100), innerRadius: 20, ringWidth: 30)
        #expect(hit?.ring == 2)
    }

    @Test("Items too small to see merge into one remainder in both layouts")
    func remainders() throws {
        let tree = try TempTree()
        try tree.file("big.bin", bytes: 4_000_000)
        for index in 0..<30 { try tree.file("d\(index)/tiny.bin", bytes: 4_000) }
        let result = try scan(tree.root)
        let arcs = Sunburst.layout(result.root, minSweep: 0.05).filter { $0.ring == 1 }
        guard case .remainder(_, let count, _) = arcs.last?.item else {
            Issue.record("no remainder arc")
            return
        }
        #expect(count == 30)
        #expect(arcs.count == 2)
        let cells = Treemap.visibleItems(of: result.root, area: 10_000, minCellArea: 100)
        #expect(cells.count == 2)
        #expect(cells.last?.name == "30 more items")
    }
}

@Suite("Live scan view")
struct LiveScanTests {
    @Test("The root's subfolders are available to live readers without touching the tree being finalized")
    func liveChildren() throws {
        let tree = try TempTree()
        try tree.file("a/x.bin", bytes: 10_000)
        try tree.file("b/y.bin", bytes: 20_000)
        let progress = ScanProgress()
        let result = try Scanner().scan(tree.root, progress: progress)
        #expect(Set(progress.liveChildren.map(\.name)) == ["a", "b"])
        #expect(Set(progress.liveChildren.map(ObjectIdentifier.init)) == Set(result.root.children.map(ObjectIdentifier.init)))

        let multi = ScanProgress()
        _ = try Scanner().scan(roots: [tree.path("a"), tree.path("b")], progress: multi)
        #expect(multi.liveChildren.map(\.name) == [tree.path("a"), tree.path("b")])
    }
}
