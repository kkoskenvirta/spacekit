import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI

struct TrashCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trash",
        abstract: "How much the Trash holds (it still uses disk space), and empty it.",
        discussion: """
            SpaceKit moves things to the Trash by default, so they can be put back. The space is only released
            when the Trash is emptied. `spacekit trash --empty` previews; add --yes to delete permanently.
            """
    )

    struct Status: Encodable {
        var path: String
        var bytes: UInt64
        var files: UInt64
    }

    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Empty the Trash (preview unless --yes).") var empty = false
    @Flag(name: [.short, .long], help: "Delete without asking.") var yes = false
    @Flag(name: .long, help: "Machine-readable output.") var json = false

    func run() throws {
        // Entries moved to the Trash after this weren't in the preview, so the executor leaves them.
        let started = Date()
        let context = global.loadContext()
        let path = Trash.path()
        let tree = try Scanner(options: Trash.scanOptions(context.scanOptions)).scan(path)
        guard !tree.root.flags.contains(.unreadable) else {
            Output.warn("Can't read the Trash. Give your terminal Full Disk Access (see `spacekit doctor`), or empty it in Finder.")
            throw ExitCode.failure
        }
        let status = Status(path: path, bytes: tree.root.size, files: tree.root.fileCount)
        if !json { print("Trash: ".bold + ByteCount.format(status.bytes).bold + "  \(status.files.formatted()) files".dim) }
        guard empty else {
            if json { try Output.json(status) } else if status.bytes > 0 { print("Empty it with: ".dim + "spacekit trash --empty".bold) }
            return
        }
        // `--empty --json` always answers in the documented `{"plan": …}` shape, even with nothing to empty.
        guard status.bytes > 0 || json else { return }
        let plan = Trash.emptyingPlan(tree, rules: context.library.rules, created: started)
        guard
            let report = try CleanupOutput.session(
                plan, executor: context.executor, yes: yes, json: json, interactive: true, heading: "Empty the Trash",
                verb: "Delete", hint: "Nothing deleted. Run with --yes to empty the Trash.")
        else { return }
        if !json, let capacity = VolumeCapacity.of(path: "/"), capacity.purgeable > 1_000_000_000,
            !LocalSnapshots.list().isEmpty
        {
            print("Local Time Machine snapshots still reference these files; the space shows as purgeable until macOS releases it.".dim)
        }
        try CleanupOutput.exitIfProblems(report)
    }
}
