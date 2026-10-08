import Foundation

/// The person's Trash: where it is, how to measure it, and the plan that empties it.
public enum Trash {
    /// `~/.Trash` for `home`.
    public static func path(home: String = PathUtil.home) -> String { PathUtil.join(home, ".Trash") }

    /// Scan options for measuring the Trash: the front end's options, kept to the Trash's own device.
    public static func scanOptions(_ options: ScanOptions) -> ScanOptions {
        var options = options
        options.boundary = .device
        return options
    }

    /// Rules that describe the Trash itself (`system.trash`), whose findings change when it's emptied.
    public static func rules(in rules: [Rule], home: String = PathUtil.home) -> [Rule] {
        let trash = path(home: home)
        return rules.filter { $0.paths.contains { PathUtil.expand($0, home: home) == trash } }
    }

    /// Permanently deleting what `scan` (a scan of the Trash) found: each entry at the top of the Trash, and the
    /// files directly inside it. `created` is when the scan started; the executor leaves anything that arrived
    /// after it, since that wasn't in the preview. Empty when the Trash holds nothing with any size.
    public static func emptyingPlan(_ scan: ScanTree, rules: [Rule], created: Date, home: String = PathUtil.home) -> CleanupPlan {
        let root = scan.root
        let ruleID = Trash.rules(in: rules, home: home).first?.id
        var plan = CleanupPlan(useTrash: false, created: created)
        plan.items = root.children.filter { $0.size > 0 }.map {
            CleanupItem(path: $0.path, kind: .directory, name: $0.name, size: $0.size, ruleID: ruleID)
        }
        if root.directFileSize > 0 {
            plan.items.append(
                CleanupItem(
                    path: root.path, kind: .looseFiles, name: "Files in the Trash", size: root.directFileSize, ruleID: ruleID,
                    looseFileNames: FindingItem.plainFileNames(in: root.path)))
        }
        return plan
    }
}
