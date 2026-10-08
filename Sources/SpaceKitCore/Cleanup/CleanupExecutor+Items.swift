import Foundation

extension CleanupExecutor {
    enum RemovalMethod {
        case trash, delete

        var journalMethod: JournalEntry.Method { self == .trash ? .trash : .delete }
    }

    static let stalePlan = "This plan predates per-file checks; refresh it"

    func removeItem(_ item: CleanupItem, plan: CleanupPlan, context: CleanupContext, run: inout Run) -> CleanupOutcome {
        var st = stat()
        guard lstat(item.path, &st) == 0 else { return .skipped(reason: "Already gone") }
        let isFolder = (st.st_mode & S_IFMT) == S_IFDIR
        let rule = item.ruleID.flatMap { rules[$0] }
        let inTrash = isInsideTrash(item.path, orTrashItself: item.kind == .looseFiles)
        guard let removal = removal(useTrash: plan.useTrash || alwaysTrash, rule: rule, inTrash: inTrash, context: context) else {
            return .skipped(reason: "Automatic runs delete things already in the Trash only when a regenerable (safe) rule covers them")
        }
        let context = CleanupExecutor.context(context, trashing: removal == .trash)

        // Loose files and Trash entries can appear after the preview; only what existed then may go.
        var created: Date?
        if item.kind == .looseFiles || inTrash {
            guard let planCreated = plan.created, item.kind != .looseFiles || item.looseFileNames != nil else {
                return .skipped(reason: CleanupExecutor.stalePlan)
            }
            created = planCreated
            if inTrash && item.kind != .looseFiles && CleanupExecutor.changed(st, after: planCreated) {
                return .skipped(reason: "Moved to the Trash after this plan was made")
            }
        }

        // The folder whose entries change: the parent for an item, the folder itself for loose files.
        let directory = item.kind == .looseFiles ? item.path : PathUtil.parent(item.path)
        guard let checkedDirectory = resolve(directory) else { return .skipped(reason: "Already gone") }

        let isRepository = item.isRepository || (isFolder && RepositoryProbe.isRepository(item.path))
        let containsRepository = item.containsRepository || (isFolder && RepositoryProbe.containsRepository(item.path))
        let confirmed = CleanupExecutor.isConfirmed(context)
        // What the preview showed: the plan's own facts. A warning beyond those was never confirmed.
        let reviewed = verdict(for: item, context: context)
        func check(size: UInt64) -> CleanupOutcome? {
            let fresh = verdict(
                for: item, size: size, isRepository: isRepository, containsRepository: containsRepository, context: context,
                checkedDirectory: checkedDirectory)
            guard fresh.permits(confirmed: confirmed) else { return CleanupExecutor.refusal(fresh) }
            return CleanupExecutor.unreviewedWarnings(fresh, reviewed: reviewed)
        }
        if let refused = check(size: item.size) { return refused }

        if item.kind == .looseFiles, let created {
            if run.dryRun { return .wouldRemove(bytes: item.size) }
            guard resolve(directory) == checkedDirectory else { return CleanupExecutor.changedWhileChecking(directory) }
            return removeLooseFiles(item, in: checkedDirectory, removal: removal, created: created, context: context, run: &run)
        }

        // Charge the budget and report what's there now, not what the scan saw.
        let measured: Measured =
            run.dryRun ? Measured(size: item.size, freed: item.size) : measure(item.path, isFolder: isFolder, fallback: item.size)
        let size = measured.size
        if size != item.size, let refused = check(size: size) { return refused }
        if context.isAutomatic && size > run.budget { return overBudget() }
        if run.dryRun { return .wouldRemove(bytes: size) }
        guard resolve(directory) == checkedDirectory else { return CleanupExecutor.changedWhileChecking(directory) }

        let name = PathUtil.lastComponent(item.path)
        var trashedTo: String?
        do {
            switch removal {
            case .delete:
                try SafeRemoval.delete(name, inDirectory: checkedDirectory)
            case .trash:
                try SafeRemoval.verifyUnchanged(checkedDirectory)
                trashedTo = try trash(PathUtil.join(checkedDirectory, name)) ?? trashDirectory
            }
        } catch {
            // Moving to the Trash is all or nothing; a deletion may have removed part of the item before it stopped.
            guard removal == .delete else { return .failed(reason: error.localizedDescription) }
            return partlyDeleted(item, before: measured, isFolder: isFolder, error: error, context: context, run: &run)
        }
        run.charge(size)
        record(
            entry(
                path: item.path, bytes: measured.freed, method: removal.journalMethod, ruleID: item.ruleID, context: context,
                trashedTo: trashedTo),
            in: &run)
        return .removed(bytes: measured.freed, trashedTo: trashedTo)
    }

    /// A deletion that stopped part way: what's no longer there is charged, journaled and reported, so the budget
    /// and the totals match the disk. The item still counts as failed, with what was deleted in the reason.
    private func partlyDeleted(
        _ item: CleanupItem, before: Measured, isFolder: Bool, error: Error, context: CleanupContext, run: inout Run
    ) -> CleanupOutcome {
        let reason = error.localizedDescription
        var st = stat()
        let left = lstat(item.path, &st) == 0 ? measure(item.path, isFolder: isFolder, fallback: before.size) : Measured(size: 0, freed: 0)
        let gone = before.size - min(before.size, left.size)
        let freed = before.freed - min(before.freed, left.freed)
        guard gone > 0 else { return .failed(reason: reason) }
        run.charge(gone)
        run.report.partiallyFreed[item.path] = freed
        record(entry(path: item.path, bytes: freed, method: .delete, ruleID: item.ruleID, context: context), in: &run)
        return .failed(reason: "\(reason). \(ByteCount.format(freed)) of it was deleted")
    }

    /// Removes the plain files directly inside the checked folder, leaving subfolders alone. Each file is checked
    /// by the guard, charged to the budget and journaled on its own, so a partial failure keeps an exact record.
    private func removeLooseFiles(
        _ item: CleanupItem, in directory: String, removal: RemovalMethod, created: Date, context: CleanupContext, run: inout Run
    ) -> CleanupOutcome {
        let names = item.looseFileNames ?? []
        let fd: Int32
        do {
            fd = try SafeRemoval.openDirectory(directory)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
        defer { close(fd) }

        let rule = item.ruleID.flatMap { rules[$0] }
        let confirmed = CleanupExecutor.isConfirmed(context)
        var totalFreed: UInt64 = 0
        var trashLocations: [String] = []
        var removedCount = 0
        var overBudgetCount = 0
        var failures: [String] = []
        for name in names {
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { continue }
            guard !CleanupExecutor.changed(st, after: created) else { continue }
            let path = PathUtil.join(item.path, name)
            let verdict = CleanupExecutor.judge(path, checked: PathUtil.join(directory, name)) { candidate in
                safety.evaluate(path: candidate, rule: rule, context: context)
            }
            guard verdict.permits(confirmed: confirmed) else { continue }
            let size = FileSize.allocated(st)
            let freed = CleanupExecutor.isLastLink(st) ? size : 0
            if context.isAutomatic && size > run.budget {
                overBudgetCount += 1
                continue
            }
            do {
                var trashedTo: String?
                switch removal {
                case .delete:
                    if unlinkat(fd, name, 0) != 0 { throw SafeRemoval.posixError(path) }
                case .trash:
                    try SafeRemoval.verifyUnchanged(directory)
                    trashedTo = try trash(PathUtil.join(directory, name)) ?? trashDirectory
                }
                totalFreed &+= freed
                removedCount += 1
                trashedTo.map { trashLocations.append($0) }
                run.charge(size)
                record(
                    entry(
                        path: path, bytes: freed, method: removal.journalMethod, ruleID: item.ruleID, context: context,
                        trashedTo: trashedTo),
                    in: &run)
            } catch {
                failures.append("Couldn't remove \(PathUtil.abbreviate(path, home: safety.home)): \(error.localizedDescription)")
            }
        }

        let budgetNote = overBudgetCount > 0 ? "\(overBudgetCount) loose files over this run's budget were left" : nil
        guard removedCount > 0 else {
            if let first = failures.first {
                return .failed(reason: first + (failures.count > 1 ? " (and \(failures.count - 1) more)" : ""))
            }
            return .skipped(reason: budgetNote ?? "None of the files from the reviewed plan are left")
        }
        run.report.warnings += failures
        if !trashLocations.isEmpty { run.report.trashedLooseFiles[item.path] = trashLocations }
        if let budgetNote { run.report.warnings.append("\(PathUtil.abbreviate(item.path, home: safety.home)): \(budgetNote)") }
        return .removed(bytes: totalFreed, trashedTo: removal == .trash ? trashLocations.first.map(PathUtil.parent) : nil)
    }

    /// How an item leaves its place. `nil`: it may not leave at all.
    ///
    /// Things already in the Trash can only be deleted, and automatic runs delete only regenerable (safe) items:
    /// anything else they remove goes to the Trash.
    func removal(useTrash: Bool, rule: Rule?, inTrash: Bool, context: CleanupContext) -> RemovalMethod? {
        let isSafe = rule?.safety.level == .safe
        if inTrash { return context.isAutomatic && !isSafe ? nil : .delete }
        return useTrash || (context.isAutomatic && !isSafe) ? .trash : .delete
    }

    /// Tells the guard whether this item will actually be trashed, which its personal-folder rule depends on.
    static func context(_ context: CleanupContext, trashing: Bool) -> CleanupContext {
        guard case .automatic(var automation) = context else { return context }
        automation.usesTrash = trashing
        return .automatic(automation)
    }

    var trashDirectory: String { Trash.path(home: safety.home) }

    /// True inside the guard's home Trash, whatever the spelling or symlinks in the parent path.
    func isInsideTrash(_ path: String, orTrashItself: Bool) -> Bool {
        let trashKeys = Set([trashDirectory, PathUtil.realpath(trashDirectory) ?? trashDirectory].map(PathUtil.comparisonKey))
        let candidates = [path, PathUtil.resolveParent(path)].map(PathUtil.comparisonKey)
        return candidates.contains { candidate in
            trashKeys.contains { trash in
                orTrashItself ? PathUtil.isAncestorOrEqual(trash, of: candidate) : PathUtil.isStrictAncestor(trash, of: candidate)
            }
        }
    }

    /// Modified or had its status changed (created, renamed into place) after `date`.
    static func changed(_ st: stat, after date: Date) -> Bool {
        func time(_ ts: timespec) -> Date { Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9) }
        return time(st.st_mtimespec) > date || time(st.st_ctimespec) > date
    }

    /// Starts the skip reason of an item that gained a warning after the preview. Reports treat it as a problem,
    /// because the person never saw that warning.
    public static let changedSinceReview = "Changed since you reviewed it: "

    /// Confirmation covers the warnings the person saw. A warning that is new at removal time (a repository that
    /// appeared, a folder that grew past the volume-share limit) skips the item instead.
    static func unreviewedWarnings(_ fresh: SafetyVerdict, reviewed: SafetyVerdict) -> CleanupOutcome? {
        guard fresh.decision == .confirm else { return nil }
        let seen = Set(reviewed.reasons.map(reasonKey))
        let unseen = fresh.reasons.filter { !seen.contains(reasonKey($0)) }
        guard !unseen.isEmpty else { return nil }
        return .skipped(reason: changedSinceReview + unseen.joined(separator: "; "))
    }

    /// A reason without its numbers: a volume share shown as 12% in the preview is the same warning at 13%.
    static func reasonKey(_ reason: String) -> String {
        String(reason.unicodeScalars.filter { !CharacterSet.decimalDigits.contains($0) })
    }

    static func changedWhileChecking(_ directory: String) -> CleanupOutcome {
        .failed(reason: "\(directory) changed while it was being checked; nothing was removed")
    }

    /// What an item holds at removal time. `size` is all of it, charged to the budget; `freed` leaves out files
    /// with another hard link outside the item, whose bytes stay on disk.
    struct Measured {
        var size: UInt64
        var freed: UInt64
    }

    /// Measures an item now. Folders are rescanned; a symlink counts as itself.
    func measure(_ path: String, isFolder: Bool, fallback: UInt64) -> Measured {
        guard isFolder else {
            var st = stat()
            guard lstat(path, &st) == 0 else { return Measured(size: fallback, freed: fallback) }
            let size = FileSize.allocated(st)
            return Measured(size: size, freed: CleanupExecutor.isLastLink(st) ? size : 0)
        }
        var options = ScanOptions()
        options.minFileSize = .max
        guard let tree = try? Scanner(options: options).scan(roots: [path]) else { return Measured(size: fallback, freed: fallback) }
        let size = tree.root.size
        return Measured(size: size, freed: size - min(size, tree.bytesLinkedOutside()))
    }

    /// True unless `st` is a regular file with another hard link, which keeps its bytes on disk.
    static func isLastLink(_ st: stat) -> Bool {
        (st.st_mode & S_IFMT) != S_IFREG || st.st_nlink <= 1
    }

    /// Allocated size of folders, the way the scanner counts it. `nil` if none could be scanned.
    func measure(_ paths: [String]) -> UInt64? {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return 0 }
        var options = ScanOptions()
        options.minFileSize = .max
        return try? Scanner(options: options).scan(roots: existing).root.size
    }
}
