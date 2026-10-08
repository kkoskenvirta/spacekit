import SpaceKitCore
import SwiftUI
import Yams

/// Browse the community rule library and your own rules.
struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selectedID: String?

    private var rules: [Rule] {
        let all = model.library.rules.sorted { ($0.group, $0.name) < ($1.group, $1.name) }
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search)
                || $0.id.localizedCaseInsensitiveContains(search) || $0.paths.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        HSplitView {
            List(selection: $selectedID) {
                let grouped = Dictionary(grouping: rules, by: \.group)
                ForEach(grouped.keys.sorted(), id: \.self) { group in
                    Section(group) {
                        ForEach(grouped[group] ?? []) { rule in
                            HStack {
                                Image(systemName: Theme.symbol(for: rule.safety.level)).foregroundStyle(Theme.color(for: rule.safety.level))
                                Text(rule.name)
                                Spacer()
                                if let finding = model.analysis?.finding(ruleID: rule.id) {
                                    Text(finding.size.formattedBytes).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .tag(rule.id)
                        }
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 340)
            .searchable(text: $search, placement: .sidebar, prompt: "Search rules")

            Group {
                if let id = selectedID, let rule = model.library.rule(id: id) {
                    RuleDetail(rule: rule)
                } else {
                    libraryOverview
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Rules Library")
        .toolbar {
            ToolbarItemGroup {
                Button("Reload", systemImage: "arrow.clockwise") { model.reloadContext() }
                    .help("Re-read rule files and the config from disk")
                Button("Open Rules Folder", systemImage: "folder") {
                    try? model.paths.ensureUserRulesDirectory()
                    model.reveal(model.paths.userRulesDirectory)
                }
                Button("New Rule…", systemImage: "plus") { newRule() }
            }
        }
    }

    private var libraryOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(
                    title: "Storage Rules",
                    subtitle:
                        "\(model.library.rules.count) rules describe where tools keep data, how risky it is to remove, and how to clean it."
                )
                Text(
                    "Rules are plain YAML. Add your own in `~/.config/spacekit/rules/`, or contribute to the built-in library in the project's `rules/` folder. A rule with the same id as a built-in one replaces it, unless the built-in rule is “Don't touch” or the replacement would lower its safety level."
                )
                .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(SafetyLevel.allCases, id: \.self) { level in
                        StatTile(
                            title: level.title, value: "\(model.library.rules.filter { $0.safety.level == level }.count)",
                            symbol: Theme.symbol(for: level), tint: Theme.color(for: level))
                    }
                }
                let issues = model.library.issues
                if !issues.isEmpty {
                    Text("Problems").font(.headline)
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue.description, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                            .foregroundStyle(issue.severity == .error ? Theme.critical : Theme.warning)
                            .font(.callout)
                    }
                }
            }
            .padding(24)
        }
    }

    private func newRule() {
        let directory = model.paths.userRulesDirectory
        try? model.paths.ensureUserRulesDirectory()
        var path = directory + "/my-rule.yaml"
        var index = 2
        while FileManager.default.fileExists(atPath: path) {
            path = directory + "/my-rule-\(index).yaml"
            index += 1
        }
        let rule = RuleScaffold.rule(name: "My tool's cache", paths: ["~/Library/Caches/com.example.tool"])
        guard let template = try? RuleScaffold.yaml(rule, note: "save, then click Reload in SpaceKit") else { return }
        try? SpaceKitPaths.writeRuleFile(template, to: path)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

private struct RuleDetail: View {
    @Environment(AppModel.self) private var model
    let rule: Rule

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.name).font(.title2.weight(.semibold))
                        Text("\(rule.group) · \(rule.id)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    SafetyBadge(level: rule.safety.level)
                }
                if let description = rule.description { Text(description) }
                if let finding = model.analysis?.finding(ruleID: rule.id) {
                    FindingCard(finding: finding)
                } else if model.analysis != nil {
                    Text("Nothing found on this Mac.").foregroundStyle(.secondary)
                }
                Text("Definition").font(.headline)
                Text((try? YAMLEncoder().encode(rule)) ?? "")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                if let source = rule.source {
                    HStack {
                        Text(PathUtil.abbreviate(source)).font(.caption).foregroundStyle(.secondary)
                        Button("Reveal") { model.reveal(source) }.buttonStyle(.link).font(.caption)
                    }
                }
                if rule.safety.level != .protected && rule.action.isCleanable {
                    Button("Automate This Rule…") { model.jobDraft = JobDraft(rule: rule) }
                }
            }
            .padding(24)
        }
    }
}
