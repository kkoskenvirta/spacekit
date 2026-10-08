import SpaceKitCore
import SwiftUI

struct AutomationView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    SectionTitle(
                        title: "Automatic Cleanup", subtitle: "Don't open the app and click Clean. Set rules once; SpaceKit keeps watch.")
                    Button("New Job", systemImage: "plus") {
                        model.jobDraft = JobDraft(job: Job(id: "new-job", name: "New job", rules: [], mode: .suggest))
                    }
                    .buttonStyle(.borderedProminent)
                }
                RecoveredBanner()
                AgentCard()
                if !model.suggestions.isEmpty { SuggestionsSection() }
                if model.config.jobs.isEmpty {
                    ContentUnavailableView {
                        Label("No jobs yet", systemImage: "clock.arrow.2.circlepath")
                    } description: {
                        Text("Create one here, or use “Automate…” on any card in Dev Intelligence.")
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12)], spacing: 12) {
                        ForEach(model.config.jobs) { job in JobCard(job: job) }
                    }
                }
                NextRunFooter()
                PoliciesExplainer()
            }
            .padding(24)
        }
        .navigationTitle("Automation")
        .onAppear { model.refreshAutomation() }
    }
}

private struct RecoveredBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.uturn.backward.circle.fill").font(.system(size: 36)).foregroundStyle(Theme.good)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Mac has recovered").foregroundStyle(.secondary)
                Text(model.recovered90Days.formattedBytes).font(.system(size: 30, weight: .semibold)).monospacedDigit()
                Text("over the last 3 months · \(model.journal.count) cleanups").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(Theme.good.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AgentCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.agentStatus
        // What launchd runs with can differ from the config after a hand edit, so show the installed interval.
        let configured = LaunchAgent.clampedInterval(model.config.automation.checkEvery.seconds)
        let interval = status?.interval ?? configured
        HStack(spacing: 12) {
            Image(systemName: status?.loaded == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(status?.loaded == true ? Theme.good : Theme.warning)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(status?.loaded == true ? "Background agent is running" : "Background agent isn't running").font(.headline)
                Text(
                    status?.loaded == true
                        ? "Checks for due jobs every \(Age(seconds: TimeInterval(interval)).description). Runs as you, never as root. Missed runs catch up after sleep."
                        : "Jobs only run on schedule when the agent is installed. It's a small per-user launchd job."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status?.installed == true {
                if interval != configured {
                    Button("Apply New Interval") { model.installAgent() }
                        .help("Settings say every \(Age(seconds: TimeInterval(configured)).description); the agent still uses the old interval")
                }
                Button("Remove") { model.uninstallAgent() }
            } else {
                Button("Install Agent") { model.installAgent() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SuggestionsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Waiting for your approval", systemImage: "tray.and.arrow.down").font(.headline)
            ForEach(model.suggestions) { suggestion in
                HStack {
                    VStack(alignment: .leading) {
                        Text(suggestion.jobName).font(.callout.weight(.semibold))
                        Text("\(suggestion.plan.items.count) items · prepared \(suggestion.created.relativeDescription())").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(suggestion.plan.totalBytes.formattedBytes).monospacedDigit()
                    Button("Dismiss") { model.dismiss(suggestion) }
                    Button("Review…") { model.approve(suggestion) }.buttonStyle(.borderedProminent)
                        .disabled(model.runningJobID != nil)
                }
                .padding(12)
                .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct JobCard: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        let state = model.jobStates[job.id]
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(job.name).font(.headline)
                    Spacer()
                    Toggle(
                        "Enabled",
                        isOn: Binding(
                            get: { job.enabled },
                            set: { on in
                                var changed = job
                                changed.enabled = on
                                model.saveJob(changed, replacing: job.id)
                            })
                    )
                    .toggleStyle(.switch).labelsHidden()
                }
                Text(job.conditionSummary).font(.callout)
                Picker(
                    "Mode",
                    selection: Binding(
                        get: { job.mode },
                        set: { mode in
                            var changed = job
                            changed.mode = mode
                            model.saveJob(changed, replacing: job.id)
                        })
                ) {
                    ForEach(Job.Mode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(job.mode.explanation).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Label(job.schedule.description, systemImage: "calendar")
                    if let matched = state?.lastMatchedBytes { Label(matched.formattedBytes, systemImage: "chart.bar") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let outcome = state?.lastOutcome {
                    Text("Last run \(state?.lastRun?.relativeDescription() ?? ""): \(outcome)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack {
                    Button("Run Now…") { model.previewJob(job) }
                        .disabled(model.runningJobID != nil)
                    if model.runningJobID == job.id { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Edit…") { model.jobDraft = JobDraft(job: job, originalID: job.id) }
                }
                .controlSize(.small)
            }
        }
        .opacity(job.enabled ? 1 : 0.6)
    }
}

private struct NextRunFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let next = model.jobRunner.nextRuns().first {
            let estimate = model.jobRunner.estimatedRecovery(states: model.jobStates)
            VStack(alignment: .leading, spacing: 4) {
                Text("Next automatic cleanup").font(.headline)
                Text(
                    "\(next.date.formatted(.dateTime.weekday(.wide))) · \(next.date.formatted(date: .omitted, time: .shortened)) — \(next.job.name)"
                )
                if estimate.high > 0 {
                    Text("Estimated recovery: \(estimate.low.formattedBytes)–\(estimate.high.formattedBytes)").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PoliciesExplainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DisclosureGroup("How automation stays safe") {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "• **Observe** tells you when something gets large. **Suggest** prepares a cleanup and asks first. **Automatic** cleans on schedule."
                )
                Text(
                    "• Automatic jobs only remove 🟢 regenerable items, unless you include 🟡 review items for that job. 🔴 items are never removed."
                )
                Text(
                    "• Every item is re-checked right before removal. Repositories, personal folders, system locations and anything you protect are refused."
                )
                Text(
                    "• A run never removes more than your per-run limit (\(model.config.safety.maxBytesPerRun.description)), and you're notified of everything it did."
                )
                Text("• Every removal is journaled; by default things go to the Trash.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
    }
}

// MARK: - Job editor

struct JobEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: JobDraft
    @State private var ruleSearch = ""
    @State private var newPath = ""
    @State private var sizeText = ""
    @State private var olderText = ""
    @State private var keepText = ""
    @State private var time = Date()
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.job.name)
                    Picker("Mode", selection: $draft.job.mode) {
                        ForEach(Job.Mode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    Text(draft.job.mode.explanation).font(.caption).foregroundStyle(.secondary)
                }
                Section("What to clean") {
                    rulePicker
                    ForEach(draft.job.paths, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder")
                            Text(path)
                            Spacer()
                            Button {
                                draft.job.paths.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Add a folder (~/Downloads)", text: $newPath).onSubmit(addPath)
                        Button("Choose…") { chooseFolder() }
                        Button("Add", action: addPath).disabled(newPath.isEmpty)
                    }
                    if !draft.job.paths.isEmpty {
                        Picker("Clean", selection: $draft.job.granularity) {
                            Text("Each item inside the folder").tag(Granularity.children)
                            Text("The folder itself").tag(Granularity.whole)
                        }
                    }
                }
                Section("When") {
                    Picker("Every", selection: $draft.job.schedule.every) {
                        ForEach(Schedule.Frequency.allCases, id: \.self) { frequency in Text(frequency.rawValue.capitalized).tag(frequency)
                        }
                    }
                    if draft.job.schedule.every == .weekly {
                        Picker(
                            "On",
                            selection: Binding(get: { draft.job.schedule.weekday ?? .sunday }, set: { draft.job.schedule.weekday = $0 })
                        ) {
                            ForEach(Weekday.allCases, id: \.self) { day in Text(day.title).tag(day) }
                        }
                    }
                    if draft.job.schedule.every == .monthly {
                        Stepper(
                            "Day \(draft.job.schedule.day ?? 1)",
                            value: Binding(get: { draft.job.schedule.day ?? 1 }, set: { draft.job.schedule.day = $0 }), in: Schedule.monthDays)
                    }
                    DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                    TextField("Only when larger than", text: $sizeText, prompt: Text("e.g. 30GB (optional)"))
                    TextField("Only items untouched for", text: $olderText, prompt: Text("e.g. 60d (optional)"))
                    TextField("Keep items used within", text: $keepText, prompt: Text("e.g. 14d (optional)"))
                }
                Section("How") {
                    Picker("Removed items", selection: $draft.job.action) {
                        Text("Move to Trash").tag(Job.Action.trash)
                        Text("Delete permanently").tag(Job.Action.delete)
                        Text("Follow each rule").tag(Job.Action.rule)
                    }
                    Toggle("Include 🟡 review items in automatic runs", isOn: $draft.job.includeReview)
                    Toggle("Enabled", isOn: $draft.job.enabled)
                }
            }
            .formStyle(.grouped)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.critical).padding(.horizontal, 20)
            }
            HStack {
                if draft.originalID != nil {
                    Button("Delete Job", role: .destructive) {
                        model.deleteJob(draft.job)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 560, height: 680)
        .onAppear(perform: load)
    }

    private var rulePicker: some View {
        let cleanable = model.library.rules.filter { $0.safety.level != .protected && $0.action.isCleanable }
        let filtered =
            ruleSearch.isEmpty
            ? cleanable
            : cleanable.filter {
                $0.name.localizedCaseInsensitiveContains(ruleSearch) || $0.group.localizedCaseInsensitiveContains(ruleSearch)
                    || $0.id.contains(ruleSearch.lowercased())
            }
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Search rules", text: $ruleSearch)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered) { rule in
                        Toggle(
                            isOn: Binding(
                                get: { draft.job.rules.contains(rule.id) },
                                set: { on in
                                    if on { draft.job.rules.append(rule.id) } else { draft.job.rules.removeAll { $0 == rule.id } }
                                })
                        ) {
                            HStack {
                                Text(rule.name)
                                Text(rule.group).foregroundStyle(.secondary)
                                Spacer()
                                SafetyBadge(level: rule.safety.level, compact: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(height: 150)
        }
    }

    private func addPath() {
        let trimmed = newPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !draft.job.paths.contains(trimmed) else { return }
        draft.job.paths.append(trimmed)
        newPath = ""
    }

    private func chooseFolder() {
        guard let path = AppModel.askForFolder() else { return }
        newPath = PathUtil.abbreviate(path)
        addPath()
    }

    private func load() {
        sizeText = draft.job.when.sizeAbove?.description ?? ""
        olderText = draft.job.when.olderThan?.description ?? ""
        keepText = draft.job.when.keepRecent?.description ?? ""
        let (hour, minute) = Schedule.components(draft.job.schedule.at) ?? (3, 0)
        time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    private func save() {
        var job = draft.job
        func parse<T>(_ text: String, _ parser: (String) -> T?, _ label: String) -> (T?, Bool) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return (nil, true) }
            guard let value = parser(trimmed) else {
                problem = "Couldn't read \(label) “\(trimmed)”."
                return (nil, false)
            }
            return (value, true)
        }
        // Ages below a day are almost always typos (6m is six minutes, not months), so they're rejected with a hint.
        func retention(_ text: String) -> (Age?, Bool) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return (nil, true) }
            switch Age.parseRetention(trimmed) {
            case .success(let age):
                return (age, true)
            case .failure(let error):
                problem = error.message
                return (nil, false)
            }
        }
        let (size, sizeOK) = parse(sizeText, ByteCount.parse, "the size")
        let (older, olderOK) = retention(olderText)
        let (keep, keepOK) = retention(keepText)
        guard sizeOK, olderOK, keepOK else { return }
        job.when = Job.Conditions(sizeAbove: size, olderThan: older, keepRecent: keep)
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        job.schedule.at = String(format: "%02d:%02d", components.hour ?? 3, components.minute ?? 0)
        guard !job.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            problem = "Give the job a name."
            return
        }
        guard !job.rules.isEmpty || !job.paths.isEmpty else {
            problem = "Pick at least one rule or folder."
            return
        }
        if draft.originalID == nil { job.id = Rule.slug(job.name) }
        model.saveJob(job, replacing: draft.originalID)
        dismiss()
    }
}
