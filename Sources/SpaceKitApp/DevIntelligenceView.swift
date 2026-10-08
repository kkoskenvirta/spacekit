import SpaceKitCore
import SwiftUI

/// "What is actually safe to remove?" — findings grouped by safety, each explained.
struct DevIntelligenceView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: SafetyLevel?
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    SectionTitle(title: "Dev Intelligence", subtitle: "Developer storage on this Mac, and what's actually safe to remove.")
                    if model.isAnalysing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Refresh", systemImage: "arrow.clockwise") { model.analyze() }
                    }
                }
                if let analysis = model.analysis {
                    summary(analysis)
                    Picker("Show", selection: $filter) {
                        Text("All").tag(SafetyLevel?.none)
                        ForEach(SafetyLevel.allCases, id: \.self) { level in Text(level.title).tag(SafetyLevel?.some(level)) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                    ForEach(SafetyLevel.allCases, id: \.self) { level in
                        let findings = visible(analysis.findings(level))
                        if (filter == nil || filter == level) && !findings.isEmpty {
                            LevelSection(level: level, findings: findings, total: analysis.total(level))
                        }
                    }
                } else {
                    analysingState
                }
            }
            .padding(24)
        }
        .searchable(text: $search, prompt: "Filter by name or tool")
        .navigationTitle("Dev Intelligence")
    }

    private func visible(_ findings: [Finding]) -> [Finding] {
        guard !search.isEmpty else { return findings }
        return findings.filter {
            $0.rule.name.localizedCaseInsensitiveContains(search) || $0.rule.group.localizedCaseInsensitiveContains(search)
        }
    }

    private func summary(_ analysis: Analysis) -> some View {
        HStack(spacing: 12) {
            StatTile(
                title: "Regenerable", value: analysis.total(.safe).formattedBytes, detail: "Recreated automatically by its tool",
                symbol: Theme.symbol(for: .safe), tint: Theme.good)
            StatTile(
                title: "Review", value: analysis.total(.review).formattedBytes, detail: "Removable, but costs a download or rebuild",
                symbol: Theme.symbol(for: .review), tint: Theme.warning)
            StatTile(
                title: "Don't touch", value: analysis.total(.protected).formattedBytes, detail: "Identified and protected",
                symbol: Theme.symbol(for: .protected), tint: Theme.critical)
        }
    }

    private var analysingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(model.tree == nil ? "Waiting for a scan…" : "Looking for Xcode, Node, Python, Rust, Docker, AI models and more…")
                .foregroundStyle(.secondary)
            if let progress = model.analysisProgress?.snapshot, progress.files > 0 {
                Text("\(progress.bytes.formattedBytes) · \(progress.files.formatted()) files").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

private struct LevelSection: View {
    let level: SafetyLevel
    let findings: [Finding]
    let total: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(level.title, systemImage: Theme.symbol(for: level)).foregroundStyle(Theme.color(for: level)).font(.headline)
                Text(total.formattedBytes).font(.headline).monospacedDigit()
                Spacer()
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                ForEach(findings) { finding in FindingCard(finding: finding) }
            }
        }
    }

    private var explanation: String {
        switch level {
        case .safe: return "Build output and caches. Removing them costs a rebuild or re-download, nothing else."
        case .review: return "Removable, but think first: large downloads, archives, simulators, models."
        case .protected: return "Shown so you know what's here. SpaceKit never removes these."
        }
    }
}

struct FindingCard: View {
    @Environment(AppModel.self) private var model
    let finding: Finding
    @State private var expanded = false
    @State private var picked: Set<String> = []

    private var rule: Rule { finding.rule }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.name).font(.headline)
                        Text(rule.group).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.refreshingRules.contains(rule.id) { ProgressView().controlSize(.small) }
                    Text(finding.size.formattedBytes).font(.title2.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                }
                if let description = rule.description {
                    Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(finding.facts(), id: \.kind) { fact in
                        GridRow {
                            Text(fact.label).foregroundStyle(.secondary)
                            HStack {
                                Text(fact.value)
                                if fact.kind == .risk { SafetyBadge(level: rule.safety.level) }
                            }
                        }
                    }
                }
                .font(.callout)

                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(finding.items.prefix(50)) { item in
                            HStack {
                                if finding.isCleanable {
                                    Toggle(
                                        "",
                                        isOn: Binding(
                                            get: { picked.contains(item.id) },
                                            set: { on in
                                                if on { picked.insert(item.id) } else { picked.remove(item.id) }
                                            })
                                    )
                                    .labelsHidden().toggleStyle(.checkbox)
                                }
                                Text(item.displayName).lineLimit(1).truncationMode(.middle)
                                    .help(PathUtil.abbreviate(item.path))
                                Spacer()
                                if let days = item.idleDays() {
                                    Text("\(days)d").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                Text(item.size.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                                Button {
                                    model.reveal(item.path)
                                } label: {
                                    Image(systemName: "magnifyingglass")
                                }.buttonStyle(.borderless)
                            }
                            .font(.callout)
                        }
                        if finding.items.count > 50 {
                            Text("\(finding.items.count - 50) more").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(expanded ? "Hide items" : "Show items").font(.callout)
                }

                if finding.isCleanable {
                    HStack {
                        Button {
                            let items = picked.isEmpty ? nil : finding.items.filter { picked.contains($0.id) }
                            model.reviewFinding(finding, items: items)
                        } label: {
                            Text(picked.isEmpty ? "Clean \(finding.size.formattedBytes)" : "Clean \(picked.count) selected")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(rule.safety.level == .safe ? Theme.categorical[0] : Theme.warning)
                        Button("Automate…") { model.jobDraft = JobDraft(rule: rule) }
                            .help("Create a scheduled job for this rule")
                        Spacer()
                        if let url = rule.docsURL {
                            Link("Docs", destination: url).font(.callout)
                        }
                    }
                }
            }
        }
    }
}
