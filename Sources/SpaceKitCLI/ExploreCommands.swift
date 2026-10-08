import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan a folder or volume and show where the space goes."
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "Folder to scan (default: current folder). Use / for the whole startup disk.")
    var path: String = "."
    @Option(name: .shortAndLong, help: "Levels of subfolders to show.")
    var depth: Int = 1
    @Option(name: .shortAndLong, help: "Entries to show per folder.")
    var top: Int = 15
    @Option(name: .long, help: "Hide entries smaller than this (e.g. 100MB).", transform: Parse.size)
    var minSize: ByteCount?
    @Flag(name: .long, help: "Track every file individually (uses more memory).")
    var allFiles = false
    @Flag(name: .long, help: "Machine-readable output.")
    var json = false

    func validate() throws {
        guard depth >= 1 else { throw ValidationError("--depth must be 1 or more") }
        guard top >= 1 else { throw ValidationError("--top must be 1 or more") }
    }

    func run() throws {
        let context = global.loadContext()
        var options = context.scanOptions
        if allFiles { options.minFileSize = 0 }
        let minimum = minSize?.bytes ?? 0
        let tree = try ProgressReporter.run("Scanning") { try Scanner(options: options).scan(path, progress: $0) }
        let index = context.ruleIndex

        if json {
            try Output.json(ScanJSON(tree: tree, depth: depth, top: top, minSize: minimum))
            return
        }
        let root = tree.root
        let volume = tree.capacity.map { "\(Output.safe($0.name))  ·  " } ?? ""
        print(
            "\(volume)\(Output.path(root.path))  ·  " + "\(ByteCount.format(root.size))".bold
                + " in \(tree.stats.files.formatted()) files  ·  scanned in \(String(format: "%.1f", tree.stats.duration))s".dim)
        if tree.stats.errors > 0 {
            print(
                "\(tree.stats.errors) folders couldn't be read. Grant Full Disk Access to your terminal for complete results (spacekit doctor)."
                    .fg(ANSI.review))
        }
        print()
        printLevel(root, prefix: "", level: 1, index: index, minimum: minimum, parentSize: root.size)
    }

    private func printLevel(_ node: DirNode, prefix: String, level: Int, index: RuleIndex, minimum: UInt64, parentSize: UInt64) {
        let items = node.items.filter { $0.size >= minimum }
        let shown = Array(items.prefix(top))
        let largest = Double(max(shown.first?.size ?? 1, 1))
        for (offset, item) in shown.enumerated() {
            let last = offset == shown.count - 1 && items.count <= top
            let branch = depth > 1 ? (last ? "└─ " : "├─ ") : ""
            let name = Output.safe(item.name) + (item.isDirectory ? "/" : "")
            let percent = ANSI.pad(String(format: "%.0f%%", Double(item.size) / Double(max(parentSize, 1)) * 100), to: 4, alignRight: true)
            let annotation = item.note(rule: item.path.flatMap(index.rule(for:))).map { "  " + $0.terminalText } ?? ""
            let bar = ANSI.bar(fraction: Double(item.size) / largest, width: 16, color: ANSI.branches[offset % ANSI.branches.count])
            print(
                Output.size(item.size) + "  " + bar + " " + percent + "  " + prefix.dim + branch.dim + (item.isDirectory ? name.bold : name)
                    + annotation)
            if level < depth, let directory = item.directory, !directory.children.isEmpty {
                printLevel(
                    directory, prefix: prefix + (depth > 1 ? (last ? "   " : "│  ") : ""), level: level + 1, index: index, minimum: minimum,
                    parentSize: directory.size)
            }
        }
        if items.count > top {
            let rest = items.dropFirst(top).reduce(0) { $0 + $1.size }
            print(
                Output.size(rest) + "  " + String(repeating: " ", count: 22) + prefix.dim + "└─ ".dim + "\(items.count - top) more".dim)
        }
    }
}

struct ScanJSON: Encodable {
    struct Entry: Encodable {
        var name: String
        var path: String?
        var size: UInt64
        var kind: String
        var files: UInt64?
        var children: [Entry]?
    }
    var path: String
    var size: UInt64
    var files: UInt64
    var directories: UInt64
    var unreadable: UInt64
    var durationSeconds: Double
    var items: [Entry]

    init(tree: ScanTree, depth: Int, top: Int, minSize: UInt64) {
        path = tree.root.path
        size = tree.root.size
        files = tree.stats.files
        directories = tree.stats.directories
        unreadable = tree.stats.errors
        durationSeconds = tree.stats.duration
        func entries(_ node: DirNode, level: Int) -> [Entry] {
            node.items.filter { $0.size >= minSize }.prefix(top).map { item in
                let kind: String
                switch item {
                case .directory: kind = "directory"
                case .file: kind = "file"
                case .otherFiles: kind = "smallFiles"
                }
                return Entry(
                    name: item.name, path: item.path, size: item.size, kind: kind, files: item.directory?.fileCount,
                    children: level < depth ? item.directory.map { entries($0, level: level + 1) } : nil)
            }
        }
        items = entries(tree.root, level: 1)
    }
}

struct DiskCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disk",
        abstract: "Volumes, capacity and (with --breakdown) what kind of data fills them."
    )

    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Scan the startup disk and break usage down by category (Developer, Applications, …).")
    var breakdown = false
    @Flag(name: .long, help: "Machine-readable output.")
    var json = false

    func run() throws {
        let table = VolumeTable.current()
        let capacities = table.userVisibleVolumes.compactMap { VolumeCapacity.of(path: $0.mountPoint) }
        if json && !breakdown {
            try Output.json(capacities)
            return
        }
        if !json {
            for capacity in capacities {
                let fraction = capacity.usedFraction
                let color = capacity.fullness.terminalColor
                print(
                    ANSI.pad(Output.safe(capacity.name).bold, to: 24) + ANSI.bar(fraction: fraction, width: 30, color: color)
                        + "  " + "\(ByteCount.format(capacity.available)) available".bold + " of \(ByteCount.format(capacity.total))".dim
                        + "  ·  \(ByteCount.format(capacity.freeNow)) free now".dim
                        + (capacity.purgeable > 0 ? "  ·  \(ByteCount.format(capacity.purgeable)) purgeable".dim : ""))
            }
        }
        if !json, let boot = capacities.first(where: { $0.mountPoint == "/" }), boot.purgeable > 1_000_000_000 {
            let snapshots = LocalSnapshots.list().count
            print()
            print(
                ("Available counts purgeable space (as Finder does); macOS releases it automatically when it's needed."
                    + (snapshots > 0
                        ? " \(snapshots) local Time Machine snapshot\(snapshots == 1 ? "" : "s") still reference recently deleted files."
                            + " To release that space now: \(LocalSnapshots.thinCommand())"
                        : ""))
                    .dim)
        }
        guard breakdown else { return }
        let context = global.loadContext()
        let tree = try ProgressReporter.run("Scanning /") { try Scanner(options: context.scanOptions).scan("/", progress: $0) }
        let engine = RuleEngine(rules: context.library.rules, devRoots: context.config.scan.devRoots)
        let findings = engine.evaluate(tree)
        let slices = CategoryBreakdown.compute(tree: tree, findings: findings)
        if json {
            try Output.json(slices.map { ["category": $0.category.name, "bytes": String($0.size)] })
            return
        }
        print()
        let total = Double(max(tree.capacity?.used ?? tree.root.size, 1))
        for (index, slice) in slices.enumerated() {
            print(
                "  " + ANSI.pad(slice.category.name, to: 24) + Output.size(slice.size) + "  "
                    + ANSI.bar(fraction: Double(slice.size) / total, width: 28, color: ANSI.branches[index % ANSI.branches.count]))
        }
        if tree.stats.errors > 0 {
            print()
            print(
                "  \(tree.stats.errors) folders were unreadable; their contents count as Hidden. Run `spacekit doctor`.".fg(ANSI.review))
        }
    }
}
