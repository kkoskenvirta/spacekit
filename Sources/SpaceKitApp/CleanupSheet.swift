import SpaceKitCore
import SwiftUI

/// Review-before-remove. Every item and tool command shows the safety guard's verdict; blocked ones can't be
/// selected, and ones with warnings need an explicit acknowledgement.
struct CleanupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: AppModel.PendingCleanup

    /// Computed once when the sheet opens; the executor checks everything again right before removal.
    @State private var verdicts: AppModel.PlanVerdicts?
    @State private var excluded: Set<String> = []
    @State private var excludedCommands: Set<String> = []
    @State private var acknowledged = false
    @State private var useTrash = true
    @State private var phase: Phase = .review
    @State private var progress: (done: Int, total: Int, current: String) = (0, 0, "")

    enum Phase {
        case review
        case running
        case done(CleanupReport)
    }

    private var rows: [(item: CleanupItem, verdict: SafetyVerdict)] {
        verdicts?.items ?? []
    }

    private var commandRows: [(command: PlannedCommand, verdict: SafetyVerdict)] { verdicts?.commands ?? [] }

    private var selectedCommandRows: [(command: PlannedCommand, verdict: SafetyVerdict)] {
        commandRows.filter { !$0.verdict.isBlocked && !excludedCommands.contains($0.command.id) }
    }

    private var selectedPlan: CleanupPlan {
        var plan = pending.plan
        plan.items = rows.filter { !$0.verdict.isBlocked && !excluded.contains($0.item.id) }.map(\.item)
        plan.commands = selectedCommandRows.map(\.command)
        // With `safety.trash: always` the executor moves everything to the Trash whatever the plan says.
        plan.useTrash = useTrash || model.config.safety.trashesEverything
        return plan
    }

    /// Everything selected is already in the Trash (emptying it): removal means deleting for good.
    private var isEmptyingTrash: Bool {
        let trash = model.trashPath
        return !pending.plan.items.isEmpty && pending.plan.items.allSatisfy { PathUtil.isAncestorOrEqual(trash, of: $0.path) }
    }

    private var needsAcknowledgement: Bool {
        rows.contains { $0.verdict.decision == .confirm && !excluded.contains($0.item.id) }
            || selectedCommandRows.contains { $0.verdict.decision == .confirm }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch phase {
            case .review: review
            case .running: running
            case .done(let report): done(report)
            }
        }
        .padding(24)
        .frame(width: 640, height: 560)
        .onAppear { useTrash = pending.plan.useTrash }
        .task { verdicts = await model.verdicts(for: pending.plan) }
    }

    // MARK: Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(pending.title).font(.title2.weight(.semibold))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    let fileBytes = selectedPlan.items.reduce(0) { $0 + $1.size }
                    let commandBytes = selectedPlan.commands.reduce(0) { $0 + $1.estimatedBytes }
                    if !selectedPlan.items.isEmpty {
                        Text(fileBytes.formattedBytes).font(.title2.weight(.semibold)).monospacedDigit()
                    }
                    if !selectedPlan.commands.isEmpty {
                        Text("up to \(commandBytes.formattedBytes) via tools")
                            .font(selectedPlan.items.isEmpty ? .title3.weight(.semibold) : .callout)
                            .foregroundStyle(selectedPlan.items.isEmpty ? .primary : .secondary)
                    }
                }
            }
            List {
                ForEach(rows, id: \.item.id) { row in
                    CleanupRow(
                        item: row.item, verdict: row.verdict, rule: row.item.ruleID.flatMap { model.library.rule(id: $0) },
                        isIncluded: Binding(
                            get: { !row.verdict.isBlocked && !excluded.contains(row.item.id) },
                            set: { included in
                                if included { excluded.remove(row.item.id) } else { excluded.insert(row.item.id) }
                            }))
                }
                ForEach(commandRows, id: \.command.id) { row in
                    CommandRow(
                        command: row.command, verdict: row.verdict,
                        isIncluded: Binding(
                            get: { !row.verdict.isBlocked && !excludedCommands.contains(row.command.id) },
                            set: { included in
                                if included { excludedCommands.remove(row.command.id) } else { excludedCommands.insert(row.command.id) }
                            }))
                }
                ForEach(pending.plan.manualSteps, id: \.self) { step in
                    Label(step, systemImage: "hand.point.right").font(.callout).foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if verdicts == nil { ProgressView().controlSize(.small) }
            }

            if pending.plan.items.isEmpty {
                Label("The tool decides what to remove; SpaceKit measures what was freed afterwards.", systemImage: "terminal")
                    .font(.callout).foregroundStyle(.secondary)
            } else if isEmptyingTrash {
                Label(
                    "These items are already in the Trash. Removing them deletes them permanently.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout).foregroundStyle(Theme.critical)
            } else if model.config.safety.trashesEverything {
                Label("Items go to the Trash, so you can put them back. Empty the Trash to free the space.", systemImage: "trash")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Toggle("Move to Trash instead of deleting", isOn: $useTrash)
                if !useTrash {
                    Label("Deleted items can't be recovered.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.critical)
                        .font(.callout)
                }
            }
            if needsAcknowledgement {
                Toggle("I've read the warnings above and want to remove these items", isOn: $acknowledged)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Text("Every item is checked again right before it's removed.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(buttonTitle, role: .destructive) { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedPlan.isEmpty || (needsAcknowledgement && !acknowledged))
            }
        }
    }

    // MARK: Running / done

    private var running: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            Text(PathUtil.abbreviate(progress.current)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var buttonTitle: String {
        if selectedPlan.items.isEmpty { return "Run Cleanup" }
        if isEmptyingTrash { return "Delete Permanently" }
        return selectedPlan.useTrash ? "Move to Trash" : "Delete"
    }

    @ViewBuilder
    private func done(_ report: CleanupReport) -> some View {
        let problems = report.skipped + report.failures
        VStack(alignment: .leading, spacing: 12) {
            // Say exactly what happened: moving to the Trash doesn't free space yet.
            if !report.removedAnything && (report.hasProblems || !problems.isEmpty) {
                Label("Nothing was removed", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold)).foregroundStyle(Theme.warning)
            } else if report.deletedBytes > 0 || report.trashedBytes == 0 {
                Label("Freed \(report.deletedBytes.formattedBytes)", systemImage: "checkmark.circle.fill")
                    .font(.title2.weight(.semibold)).foregroundStyle(Theme.good)
            }
            if report.trashedBytes > 0 {
                Label("Moved \(report.trashedBytes.formattedBytes) to the Trash", systemImage: "trash.circle.fill")
                    .font(report.deletedBytes > 0 ? .headline : .title2.weight(.semibold))
                    .foregroundStyle(report.deletedBytes > 0 ? Color.primary : Theme.good)
                HStack {
                    Text("It still uses disk space until the Trash is emptied. You can put things back from the Trash until then.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Empty Trash…") {
                        dismiss()
                        model.emptyTrash()
                    }
                }
            }
            if report.deletedBytes > 0 && model.localSnapshotCount > 0 {
                Label(
                    "Local Time Machine snapshots still reference the deleted files, so macOS shows this space as purgeable (counted in “available”) and releases it automatically when it's needed.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !problems.isEmpty {
                Text("Left alone").font(.headline)
                List(problems, id: \.item.id) { problem in
                    VStack(alignment: .leading) {
                        Text(PathUtil.abbreviate(problem.item.path)).font(.callout)
                        Text(problem.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.bordered)
            }
            ForEach(Array(report.unfinishedCommands.enumerated()), id: \.offset) { _, problem in
                Label("\(problem.command.displayString): \(problem.reason)", systemImage: "xmark.octagon").foregroundStyle(Theme.critical)
            }
            ForEach(report.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func run() {
        let plan = selectedPlan
        let confirmed = needsAcknowledgement && acknowledged
        phase = .running
        progress = (0, plan.items.count + plan.commands.count, "")
        Task {
            let report = await model.execute(
                plan, confirmed: confirmed, completion: pending.completion,
                onProgress: { done, total, current in
                    Task { @MainActor in progress = (done, total, current) }
                })
            phase = .done(report)
        }
    }
}

struct CommandRow: View {
    let command: PlannedCommand
    let verdict: SafetyVerdict
    @Binding var isIncluded: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $isIncluded).labelsHidden().toggleStyle(.checkbox).disabled(verdict.isBlocked)
            Image(systemName: "terminal").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(command.displayString).font(.callout.monospaced())
                Text("Runs the tool's own cleanup, which removes only what the tool knows is unused · up to \(command.estimatedBytes.formattedBytes)")
                    .font(.caption).foregroundStyle(.secondary)
                VerdictReasons(verdict: verdict)
            }
        }
        .opacity(verdict.isBlocked ? 0.6 : 1)
        .padding(.vertical, 2)
    }
}

/// The guard's reasons for a verdict, each marked by its own decision: a lock for a reason that blocks, a warning
/// for one that needs confirmation (a blocked item can have both).
struct VerdictReasons: View {
    let verdict: SafetyVerdict

    var body: some View {
        ForEach(verdict.entries, id: \.reason) { (entry: SafetyVerdict.Entry) in
            let blocks: Bool = entry.decision == .block
            Label(entry.reason, systemImage: blocks ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(blocks ? Theme.critical : Theme.warning)
        }
    }
}

struct CleanupRow: View {
    let item: CleanupItem
    let verdict: SafetyVerdict
    let rule: Rule?
    @Binding var isIncluded: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $isIncluded).labelsHidden().toggleStyle(.checkbox).disabled(verdict.isBlocked)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.kind == .looseFiles ? "Files in \(PathUtil.lastComponent(item.path))" : item.name).lineLimit(1)
                        .truncationMode(.middle)
                    if let rule { SafetyBadge(level: rule.safety.level, compact: true) }
                    Spacer()
                    Text(item.size.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(PathUtil.abbreviate(item.path)).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                VerdictReasons(verdict: verdict)
            }
        }
        .opacity(verdict.isBlocked ? 0.6 : 1)
        .padding(.vertical, 2)
    }
}
