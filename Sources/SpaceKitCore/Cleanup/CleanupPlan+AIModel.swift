import Foundation

extension CleanupPlan {
    /// Removing one model from the AI view: the tool's own command when the rule declares one (it knows which
    /// files other models still share), otherwise the finding items the model is made of, or else its files and
    /// folders as they are on disk now.
    /// `nil` when there's nothing to remove on its own, like blobs several models share.
    public static func removing(_ model: AIModel, useTrash: Bool = true, created: Date = Date()) -> CleanupPlan? {
        guard model.isRemovable else { return nil }
        var plan = CleanupPlan(useTrash: useTrash, created: created)
        if let command = model.removeCommand {
            plan.commands = [
                PlannedCommand(
                    ruleID: model.ruleID, arguments: command, estimatedBytes: model.size, measurePaths: model.paths,
                    modelName: model.name)
            ]
            return plan
        }
        if !model.items.isEmpty {
            plan.items = model.items.map { CleanupItem($0, ruleID: model.ruleID) }
            return plan
        }
        let single = model.paths.count == 1
        plan.items = model.paths.map { path in
            var st = stat()
            let isDirectory = lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            return CleanupItem(
                path: path, kind: isDirectory ? .directory : .file, name: single ? model.name : PathUtil.lastComponent(path),
                size: single ? model.size : FileSize.allocated(st), ruleID: model.ruleID, lastUsed: model.lastUsed)
        }
        return plan
    }
}
