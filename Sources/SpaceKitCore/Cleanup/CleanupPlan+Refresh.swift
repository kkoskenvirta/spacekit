import Foundation

extension CleanupPlan {
    /// This plan narrowed to what `fresh` (the plan a fresh evaluation of the same job makes) still offers. A saved plan,
    /// such as a suggestion, may be days old: items used since then or no longer matching the job's age conditions
    /// must not be removed on the strength of the old preview.
    ///
    /// Items and commands are matched by id. What they carry comes from `fresh`, never from the saved file, which
    /// could have been edited since: a saved row can narrow what runs, never widen it. So a kept item has the fresh
    /// size, rule and repository facts (a repository either recorded counts), only the loose files both name, and the
    /// earlier of the two scan starts, so whatever changed after the original preview is still left alone. `useTrash`
    /// holds if either plan asks for the Trash, and the saved manual steps are kept.
    public func keeping(onlyIn fresh: CleanupPlan) -> (plan: CleanupPlan, dropped: [CleanupItem]) {
        let freshItems = Dictionary(fresh.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let freshCommands = Dictionary(fresh.commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var refreshed = self
        refreshed.items = items.compactMap { saved in freshItems[saved.id].map { saved.narrowing($0) } }
        refreshed.commands = commands.compactMap { freshCommands[$0.id] }
        refreshed.useTrash = useTrash || fresh.useTrash
        return (refreshed, items.filter { freshItems[$0.id] == nil })
    }
}

extension CleanupItem {
    /// `fresh` (the same item from a fresh evaluation), held to what this saved item offered.
    fileprivate func narrowing(_ fresh: CleanupItem) -> CleanupItem {
        var item = fresh
        item.isRepository = fresh.isRepository || isRepository
        item.containsRepository = fresh.containsRepository || containsRepository
        item.looseFileNames = looseFileNames.flatMap { saved in fresh.looseFileNames.map { names in names.filter(saved.contains) } }
        item.scanStarted = scanStarted.flatMap { saved in fresh.scanStarted.map { min(saved, $0) } }
        return item
    }
}
