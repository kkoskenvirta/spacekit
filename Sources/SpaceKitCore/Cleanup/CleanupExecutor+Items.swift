import Foundation

extension CleanupExecutor {
    static let savedWithoutScan = "This item was saved without what its scan saw; refresh the plan"
    static let notWhereReviewed = "what is at this path now isn't what you reviewed (its folder leads elsewhere, or it was replaced)"

    /// `reviewed`: what the person's review showed for this item; `nil` in an automatic run.
    func removeItem(
        _ item: CleanupItem, plan: CleanupPlan, context: CleanupContext, reviewed: ReviewRecord.Row?, run: inout Run
    ) -> CleanupOutcome {
        let remover = self.remover
        // Built once: the guard, the Trash-or-delete decision and the removal all see this location and these facts.
        let target = remover.target(of: item, probingRepositories: true)
        guard item.kind == .looseFiles ? target.directory != nil : target.exists else {
            return .skipped(reason: "Already gone", kind: .gone)
        }
        // The person's go-ahead covers what the review judged where it judged it: a parent that leads elsewhere now,
        // or another item in its place, could take an accepted warning to something they never saw.
        if let reviewed, reviewed.location != target.location {
            return .changedSinceReview(CleanupExecutor.notWhereReviewed)
        }
        let rule = item.ruleID.flatMap { rules[$0] }
        let inTrash = remover.isInsideTrash(target)
        guard let method = remover.method(inTrash: inTrash, useTrash: plan.useTrash, rule: rule, context: context) else {
            return .skipped(reason: CleanupExecutor.trashedNotRegenerable, kind: .refused)
        }
        let context = Remover.context(context, removingBy: method)
        if let notScanned = notCoveredByScan(item, target: target, inTrash: inTrash) { return notScanned }
        if let refused = refusal(of: target, item: item, context: context, reviewed: reviewed) { return refused }

        if item.kind == .looseFiles, let scanStarted = item.scanStarted {
            if run.dryRun { return .wouldRemove(bytes: item.size) }
            return removeLooseFiles(
                item, target: target, method: method, scanStarted: scanStarted, context: context, reviewed: reviewed, run: &run)
        }
        return removeWhole(item, target: target, method: method, context: context, reviewed: reviewed, run: &run)
    }

    /// Why the run may not act on `target` for `item`, or `nil` when it may: the guard's verdict held to the review.
    private func refusal(
        of target: RemovalTarget, item: CleanupItem, context: CleanupContext, reviewed: ReviewRecord.Row?
    ) -> CleanupOutcome? {
        CleanupExecutor.refusal(verdict(for: target, ruleID: item.ruleID, context: context), reviewed: reviewed)
    }

    /// Loose files and Trash entries can appear after the preview; only what existed when the item's own scan started
    /// may go. Why the item isn't covered by its scan, or `nil` when it is (or needn't be). A loose-files item that
    /// passes has a scan start.
    private func notCoveredByScan(_ item: CleanupItem, target: RemovalTarget, inTrash: Bool) -> CleanupOutcome? {
        guard item.kind == .looseFiles || inTrash else { return nil }
        guard let started = item.scanStarted, item.kind != .looseFiles || item.looseFileNames != nil else {
            return .skipped(reason: CleanupExecutor.savedWithoutScan, kind: .notScanned)
        }
        if inTrash && item.kind != .looseFiles && target.changed(after: started) {
            return .skipped(reason: "Moved to the Trash after it was scanned", kind: .notScanned)
        }
        return nil
    }

    /// Removes an item that isn't loose files as one: measured now, checked again at that size, held to the budget,
    /// then moved or deleted, charged and journaled.
    private func removeWhole(
        _ item: CleanupItem, target: RemovalTarget, method: Remover.Method, context: CleanupContext, reviewed: ReviewRecord.Row?,
        run: inout Run
    ) -> CleanupOutcome {
        // Charge the budget and report what's there now, not what the scan saw.
        let measured: Measured =
            run.dryRun
            ? Measured(size: item.size, freed: item.size) : measure(target.resolvedPath, isFolder: target.isFolder, fallback: item.size)
        let size = measured.size
        let sized = target.measured(size)
        if size != item.size, let refused = refusal(of: sized, item: item, context: context, reviewed: reviewed) { return refused }
        if context.isAutomatic && size > run.budget { return overBudget() }
        if run.dryRun { return .wouldRemove(bytes: size) }

        let removed: Remover.Removed
        do {
            removed = try remover.remove(sized, by: method, context: context)
        } catch let interrupted as Remover.Interrupted {
            // Moving to the Trash is all or nothing; a deletion may have removed part of the item before it stopped.
            return partlyDeleted(item, target: sized, before: measured, error: interrupted, context: context, run: &run)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
        // A volume mounted inside the item stays, with the folders above it; the bytes still there weren't freed.
        let left = removed.leftOnOtherVolumes.isEmpty ? .zero : measure(target.resolvedPath, isFolder: true, fallback: 0)
        let gone = measured.minus(left)
        reportLeft(removed.leftOnOtherVolumes, of: item, run: &run)
        run.charge(gone.size)
        record(
            entry(
                path: item.path, bytes: gone.freed, method: method.journalMethod, ruleID: item.ruleID, context: context,
                trashedTo: removed.trashedTo),
            in: &run)
        return .removed(bytes: gone.freed, trashedTo: removed.trashedTo)
    }

    /// A deletion that stopped part way: what's no longer there is charged, journaled and reported, so the budget
    /// and the totals match the disk. The item still counts as failed, with what was deleted in the reason.
    private func partlyDeleted(
        _ item: CleanupItem, target: RemovalTarget, before: Measured, error: Remover.Interrupted, context: CleanupContext,
        run: inout Run
    ) -> CleanupOutcome {
        let reason = error.localizedDescription
        reportLeft(error.leftOnOtherVolumes, of: item, run: &run)
        var st = stat()
        let path = target.resolvedPath
        let left = lstat(path, &st) == 0 ? measure(path, isFolder: target.isFolder, fallback: before.size) : .zero
        let gone = before.minus(left)
        guard gone.size > 0 else { return .failed(reason: reason) }
        run.charge(gone.size)
        run.report.partiallyFreed[item.path] = gone.freed
        record(entry(path: item.path, bytes: gone.freed, method: .delete, ruleID: item.ruleID, context: context), in: &run)
        return .failed(reason: "\(reason). \(ByteCount.format(gone.freed)) of it was deleted")
    }

    /// Folders inside `item` left because another volume is mounted on them, as warnings of the run.
    private func reportLeft(_ paths: [String], of item: CleanupItem, run: inout Run) {
        guard !paths.isEmpty else { return }
        run.report.leftOnOtherVolumes[item.path] = paths
        run.report.warnings += paths.map { left in
            "Left \(PathUtil.abbreviate(left, home: safety.home)): another volume is mounted there. "
                + "The rest of \(PathUtil.abbreviate(item.path, home: safety.home)) was removed."
        }
    }

    /// Removes the plain files directly inside the target's pinned folder, leaving subfolders alone. Each file is
    /// checked by the guard, charged to the budget and journaled on its own, so a partial failure keeps an exact record.
    private func removeLooseFiles(
        _ item: CleanupItem, target: RemovalTarget, method: Remover.Method, scanStarted: Date, context: CleanupContext,
        reviewed: ReviewRecord.Row?, run: inout Run
    ) -> CleanupOutcome {
        let remover = self.remover
        let fd: Int32
        do {
            fd = try remover.openDirectory(of: target)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
        defer { close(fd) }

        var tally = LooseFiles()
        for name in item.looseFileNames ?? [] {
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { continue }
            let file = target.entry(name, stat: st, namedIn: item.path)
            guard !file.changed(after: scanStarted) else { continue }
            // The review judged the folder's files as a whole, so it couldn't show a reason that belongs to one file: a
            // file refused now is left like a refused item, not as a change since the review.
            let verdict = verdict(for: file, ruleID: item.ruleID, context: context)
            if let refused = CleanupExecutor.refusal(verdict, reviewed: reviewed, unseen: { .skipped(reason: $0, kind: .refused) }) {
                tally.refusals.append((file.path, refused))
                continue
            }
            if context.isAutomatic && file.size > run.budget {
                tally.overBudget += 1
                continue
            }
            do {
                let trashedTo = try remover.remove(file, in: fd, by: method, context: context).trashedTo
                // A file with another hard link keeps its bytes on disk: charged to the budget, but not freed.
                let freed = CleanupExecutor.isLastLink(st) ? file.size : 0
                tally.freed &+= freed
                tally.removed += 1
                trashedTo.map { tally.trashLocations.append($0) }
                run.charge(file.size)
                record(
                    entry(
                        path: file.path, bytes: freed, method: method.journalMethod, ruleID: item.ruleID, context: context,
                        trashedTo: trashedTo),
                    in: &run)
            } catch {
                tally.failures.append("Couldn't remove \(PathUtil.abbreviate(file.path, home: safety.home)): \(error.localizedDescription)")
            }
        }
        return outcome(of: tally, for: item, method: method, run: &run)
    }

    /// What one loose-files item's run did, file by file.
    private struct LooseFiles {
        var freed: UInt64 = 0
        var trashLocations: [String] = []
        var removed = 0
        var overBudget = 0
        var failures: [String] = []
        /// Files the check at removal time refused, each reported, never dropped: a refusal of one file is news to the
        /// person. Like a refused item, it isn't a problem (`.refused`) unless the person left the warnings unaccepted.
        var refusals: [(path: String, outcome: CleanupOutcome)] = []
    }

    /// The item's outcome from what happened to its files. Failures are problems: they go to the report's warnings when
    /// something was removed. Files left on purpose (refused, over the budget) go to its notes then. When nothing was
    /// removed, the outcome itself says all of it.
    private func outcome(of tally: LooseFiles, for item: CleanupItem, method: Remover.Method, run: inout Run) -> CleanupOutcome {
        let budgetNote = tally.overBudget > 0 ? "\(tally.overBudget) loose files over this run's budget were left" : nil
        let refused = tally.refusals.compactMap { path, outcome -> (line: String, kind: SkipKind)? in
            guard case .skipped(let reason, let kind) = outcome else { return nil }
            let shown = PathUtil.abbreviate(path, home: safety.home)
            return (reason.contains(shown) ? "Left: \(reason)" : "Left \(shown): \(reason)", kind)
        }
        // Only a file whose warnings the person saw and didn't accept is a problem.
        let unaccepted = refused.filter(\.kind.isProblem).map(\.line)
        let leftOnPurpose = refused.filter { !$0.kind.isProblem }.map(\.line)
        let failures = tally.failures
        guard tally.removed > 0 else {
            if let first = failures.first {
                run.report.warnings += unaccepted
                run.report.notes += leftOnPurpose + (budgetNote.map { [$0] } ?? [])
                return .failed(reason: first + (failures.count > 1 ? " (and \(failures.count - 1) more)" : ""))
            }
            let left = refused.map(\.line) + (budgetNote.map { [$0] } ?? [])
            guard !left.isEmpty else { return .skipped(reason: "None of the files from the reviewed plan are left", kind: .gone) }
            let kind = refused.first(where: \.kind.isProblem)?.kind ?? (refused.isEmpty ? .overBudget : .refused)
            return .skipped(reason: left.joined(separator: "; "), kind: kind)
        }
        run.report.warnings += failures + unaccepted
        run.report.notes += leftOnPurpose
        if !tally.trashLocations.isEmpty { run.report.trashedLooseFiles[item.path] = tally.trashLocations }
        if let budgetNote { run.report.notes.append("\(PathUtil.abbreviate(item.path, home: safety.home)): \(budgetNote)") }
        return .removed(bytes: tally.freed, trashedTo: method == .trash ? tally.trashLocations.first.map(PathUtil.parent) : nil)
    }

    /// What an item holds at removal time. `size` is all of it, charged to the budget; `freed` leaves out files
    /// with another hard link outside the item, whose bytes stay on disk.
    struct Measured {
        var size: UInt64
        var freed: UInt64

        static let zero = Measured(size: 0, freed: 0)

        /// What went of this when `left` of it is still there, never less than nothing.
        func minus(_ left: Measured) -> Measured {
            Measured(size: size - min(size, left.size), freed: freed - min(freed, left.freed))
        }
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
