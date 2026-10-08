import AppKit
import Foundation
import SpaceKitCore

extension AppModel {
    // MARK: Volumes and Trash

    var trashPath: String { Trash.path() }

    private var trashScanOptions: ScanOptions { Trash.scanOptions(context.scanOptions) }

    /// Measures the Trash. With `resync`, the Trash folder in the map is replaced by the fresh scan, so
    /// emptying the Trash anywhere (Finder, Terminal, SpaceKit) shows up without a full rescan.
    func refreshTrash(resync: Bool) {
        let options = trashScanOptions
        let path = trashPath
        let context = self.context
        let trashRules = Set(Trash.rules(in: library.rules).map(\.id))
        // What's shown as the scan starts: a tree shown or analysed while it runs is newer than this scan.
        let shown = workspace.state
        Task {
            let fresh = await Task.detached(priority: .utility) { try? Scanner(options: options).scan(path) }.value
            guard let fresh, !fresh.root.flags.contains(.unreadable) else {
                trashMeasured(nil)
                return
            }
            trashMeasured(fresh.root.size)
            guard resync else { return }
            // The Trash rules' findings live in the Trash, so they are re-evaluated once it's spliced in.
            workspace.resync(fresh, at: path, over: shown, context: context, reevaluating: trashRules)
        }
    }

    /// Opens the review sheet for permanently deleting what's in the Trash.
    func emptyTrash() {
        let options = trashScanOptions
        let path = trashPath
        let rules = library.rules
        Task {
            let fresh = await Task.detached(priority: .userInitiated) { try? Scanner(options: options).scan(path) }.value
            guard let fresh, !fresh.root.flags.contains(.unreadable) else {
                errorMessage = "SpaceKit can't read the Trash. Grant Full Disk Access, or empty it in Finder."
                return
            }
            let plan = Trash.emptyingPlan(fresh, rules: rules)
            guard !plan.isEmpty else {
                errorMessage = "The Trash is already empty."
                return
            }
            review(plan, title: "Empty Trash")
        }
    }

    var bootVolume: VolumeCapacity? { volumes.first { $0.mountPoint == "/" } ?? VolumeCapacity.of(path: "/") }
}
