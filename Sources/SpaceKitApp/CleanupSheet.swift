import SpaceKitCore
import SwiftUI

/// Review-before-remove. Renders a `CleanupReview`: every item and tool command shows the safety guard's verdict;
/// blocked ones can't be selected, and ones with warnings need an explicit acknowledgement.
struct CleanupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: AppModel.PendingCleanup

    /// Built once when the sheet opens; the executor checks everything again right before removal.
    @State private var review: CleanupReview?
    @State private var acknowledged = false
    @State private var phase: Phase = .review
    @State private var progress: (done: Int, total: Int, current: String) = (0, 0, "")
    /// Set when a run was refused because the settings changed after the review, and the review was made again.
    @State private var reviewedAgain = false

    enum Phase {
        case review
        case running
        case done(CleanupReport)
    }

    private var selectedItems: [CleanupItem] { review?.selectedItems ?? [] }
    private var selectedCommands: [PlannedCommand] { review?.selectedCommands ?? [] }
    private var needsAcknowledgement: Bool { review?.needsAcknowledgement ?? false }

    private func inclusion<Subject>(_ row: CleanupReview.Row<Subject>) -> Binding<Bool> {
        Binding(get: { review?.isIncluded(row) ?? false }, set: { review = review?.setting(row, included: $0) })
    }

    private var useTrash: Binding<Bool> {
        Binding(get: { review?.useTrash ?? true }, set: { review = review?.usingTrash($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch phase {
            case .review: reviewPhase
            case .running: running
            case .done(let report): done(report)
            }
        }
        .padding(24)
        .frame(width: 640, height: 560)
        .task { review = await model.cleanupReview(of: pending.plan) }
    }

    // MARK: Review

    private var reviewPhase: some View {
        VStack(alignment: .leading, spacing: 16) {
            reviewHeader
            reviewList
            if pending.plan.items.isEmpty {
                Label("The tool decides what to remove; SpaceKit measures what was freed afterwards.", systemImage: "terminal")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let review {
                disposal(review)
            }
            if reviewedAgain {
                Label(
                    "SpaceKit's settings changed after you reviewed this, so nothing was removed. Check the list again.",
                    systemImage: "arrow.clockwise.circle.fill"
                )
                .font(.callout).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if needsAcknowledgement {
                Toggle("I've read the warnings above and want to remove these items", isOn: $acknowledged)
                    .toggleStyle(.checkbox)
            }
            reviewButtons
        }
    }

    /// The title, with what the selection frees.
    private var reviewHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(pending.title).font(.title2.weight(.semibold))
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if !selectedItems.isEmpty {
                    Text((review?.itemBytes ?? 0).formattedBytes).font(.title2.weight(.semibold)).monospacedDigit()
                }
                if !selectedCommands.isEmpty {
                    Text("up to \((review?.commandBytes ?? 0).formattedBytes) via tools")
                        .font(selectedItems.isEmpty ? .title3.weight(.semibold) : .callout)
                        .foregroundStyle(selectedItems.isEmpty ? .primary : .secondary)
                }
            }
        }
    }

    /// Every item and command with its verdict and tick box, then the manual steps.
    private var reviewList: some View {
        List {
            ForEach(review?.items ?? []) { row in
                CleanupRow(
                    item: row.subject, verdict: row.verdict, rule: row.subject.ruleID.flatMap { model.library.rule(id: $0) },
                    isIncluded: inclusion(row))
            }
            ForEach(review?.commands ?? []) { row in
                CommandRow(command: row.subject, verdict: row.verdict, isIncluded: inclusion(row))
            }
            ForEach(pending.plan.manualSteps, id: \.self) { step in
                Label(step, systemImage: "hand.point.right").font(.callout).foregroundStyle(.secondary)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .overlay {
            if review == nil { ProgressView().controlSize(.small) }
        }
    }

    private var reviewButtons: some View {
        HStack {
            Text("Every item is checked again right before it's removed.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(buttonTitle, role: .destructive) { run() }
                .keyboardShortcut(.defaultAction)
                .disabled((review?.isEmpty ?? true) || (needsAcknowledgement && !acknowledged))
        }
    }

    /// The Trash choice where the person has one, and where the items go in the review's own words.
    @ViewBuilder
    private func disposal(_ review: CleanupReview) -> some View {
        if review.canChooseTrash && review.disposal != .deleteFromTrash {
            Toggle("Move to Trash instead of deleting", isOn: useTrash)
        }
        if let summary = review.disposalSummary {
            let permanent = review.disposal.isPermanent
            Label(summary, systemImage: permanent ? "exclamationmark.triangle.fill" : "trash")
                .font(.callout).foregroundStyle(permanent ? Theme.critical : Color.secondary)
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
        guard let review, !review.selectedItems.isEmpty else { return "Run Cleanup" }
        switch review.disposal {
        case .moveToTrash: return "Move to Trash"
        case .delete: return "Delete"
        case .deleteFromTrash: return "Delete Permanently"
        case .moveToTrashAndDeleteFromTrash: return "Move to Trash and Delete"
        }
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
            ForEach(report.notes, id: \.self) { note in
                Label(note, systemImage: "minus.circle").foregroundStyle(.secondary)
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
        guard let review else { return }
        // The checkbox is the person's one acknowledgement for the whole plan, of every warning listed above.
        let reviewed = review.acknowledge(acceptingWarnings: acknowledged)
        phase = .running
        progress = (0, reviewed.plan.items.count + reviewed.plan.commands.count, "")
        Task {
            let report = await model.execute(
                reviewed, run: pending.run,
                onProgress: { done, total, current in
                    Task { @MainActor in progress = (done, total, current) }
                })
            guard report.reviewOutdated else {
                phase = .done(report)
                return
            }
            // Reviewed under settings that are no longer in force: review it again under the current ones. The verdicts
            // and the acknowledgement start over; the rows the person unticked stay unticked.
            self.review = nil
            acknowledged = false
            reviewedAgain = true
            phase = .review
            self.review = await model.cleanupReview(of: pending.plan).keepingChoices(of: review)
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
