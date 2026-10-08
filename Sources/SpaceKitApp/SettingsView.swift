import SpaceKitCore
import SwiftUI
import Yams

/// Settings edit `~/.config/spacekit/config.yaml` directly. Hand edits to the file show up after Reload.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SafetySettingsPane().tabItem { Label("Safety", systemImage: "lock.shield") }
            AutomationSettingsPane().tabItem { Label("Automation", systemImage: "clock.arrow.2.circlepath") }
            RulesSettingsPane().tabItem { Label("Rules", systemImage: "books.vertical") }
            ConfigFilePane().tabItem { Label("Config File", systemImage: "doc.text") }
        }
        .frame(width: 620, height: 520)
    }
}

/// A text field for sizes/ages/paths that commits valid values on Return or focus loss.
private struct CommitField: View {
    let title: String
    let prompt: String
    let value: String
    let validate: (String) -> Bool
    let commit: (String) -> Void
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .onAppear { text = value }
            .onChange(of: value) { _, newValue in text = newValue }
            .onSubmit(apply)
            .foregroundStyle(invalid ? Theme.critical : .primary)
            .help(invalid ? "Not a valid value" : "")
    }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        invalid = !validate(trimmed)
        if !invalid { commit(trimmed) }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scan = model.config.scan
        Form {
            Section("Scanning") {
                CommitField(
                    title: "Default location", prompt: "/", value: scan.defaultPath,
                    validate: { FileManager.default.fileExists(atPath: PathUtil.expand($0)) }
                ) { value in
                    model.updateConfig { $0.scan.defaultPath = value }
                }
                CommitField(
                    title: "Track files from", prompt: "1MB", value: scan.minFileSize.description,
                    validate: { ByteCount.parse($0) != nil }
                ) { value in
                    model.updateConfig { $0.scan.minFileSize = ByteCount.parse(value)! }
                }
                Text("Smaller files are summarised per folder. Lower values show more detail but use more memory.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker(
                    "Boundary",
                    selection: Binding(get: { scan.boundary }, set: { value in model.updateConfig { $0.scan.boundary = value } })
                ) {
                    Text("Whole disk (APFS container)").tag(ScanOptions.Boundary.container)
                    Text("This volume only").tag(ScanOptions.Boundary.device)
                    Text("Follow all mounts").tag(ScanOptions.Boundary.unrestricted)
                }
                Stepper(
                    "Worker threads: \(scan.threads.map(String.init) ?? "automatic (\(ScanOptions.defaultThreadCount))")",
                    value: Binding(
                        get: { scan.threads ?? ScanOptions.defaultThreadCount },
                        set: { value in model.updateConfig { $0.scan.threads = value } }), in: 1...32)
            }
            Section("Project search") {
                CommitField(
                    title: "Developer roots", prompt: "~, ~/Developer", value: scan.devRoots.joined(separator: ", "),
                    validate: { !$0.isEmpty }
                ) { value in
                    model.updateConfig { $0.scan.devRoots = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                }
                CommitField(
                    title: "Never scan", prompt: "~/VMs, ~/Library/Containers/com.utmapp.UTM", value: scan.exclude.joined(separator: ", "),
                    validate: { _ in true }
                ) { value in
                    model.updateConfig {
                        $0.scan.exclude = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                }
            }
            Section("Map") {
                Picker(
                    "Visualization",
                    selection: Binding(
                        get: { model.config.ui.visualization },
                        set: { value in
                            model.visualization = value
                            model.updateConfig { $0.ui.visualization = value }
                        })
                ) {
                    Text("Sectors").tag(UISettings.Visualization.sunburst)
                    Text("Treemap").tag(UISettings.Visualization.treemap)
                }
                Picker(
                    "Color by",
                    selection: Binding(
                        get: { model.config.ui.colorBy },
                        set: { value in
                            model.colorMode = value
                            model.updateConfig { $0.ui.colorBy = value }
                        })
                ) {
                    ForEach(UISettings.ColorMode.allCases, id: \.self) { mode in Text(mode.rawValue.capitalized).tag(mode) }
                }
            }
            Section {
                Button("Open Setup Guide…") { model.showOnboarding = true }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SafetySettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var newPath = ""

    var body: some View {
        let safety = model.config.safety
        Form {
            Section {
                Picker(
                    "Removed items",
                    selection: Binding(get: { safety.trash }, set: { value in model.updateConfig { $0.safety.trash = value } })
                ) {
                    Text("Always move to the Trash").tag(SafetySettings.TrashMode.always)
                    Text("Let rules delete regenerable caches directly").tag(SafetySettings.TrashMode.rules)
                }
                CommitField(
                    title: "Most an automatic run may remove", prompt: "100GB", value: safety.maxBytesPerRun.description,
                    validate: { ByteCount.parse($0) != nil }
                ) { value in
                    model.updateConfig { $0.safety.maxBytesPerRun = ByteCount.parse(value)! }
                }
            }
            Section {
                ForEach(safety.protectedPaths, id: \.self) { path in
                    HStack {
                        Image(systemName: "lock.fill").foregroundStyle(Theme.critical)
                        Text(path)
                        Spacer()
                        Button {
                            model.updateConfig { $0.safety.protectedPaths.removeAll { $0 == path } }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add a folder", text: $newPath, prompt: Text("~/Work/client-archive"))
                    Button("Add") {
                        let path = newPath.trimmingCharacters(in: .whitespaces)
                        guard !path.isEmpty else { return }
                        model.updateConfig { $0.safety.protectedPaths.append(path) }
                        newPath = ""
                    }
                }
            } header: {
                Text("Never touch")
            } footer: {
                Text(
                    "Added to SpaceKit's built-in protections (system folders, your home, Documents, credentials, repositories…), which can't be turned off."
                )
            }
            Section("Built-in protections") {
                Button("Read the Safety Guidelines…") { model.showSafety = true }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AutomationSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let automation = model.config.automation
        Form {
            Section("Background agent") {
                HStack {
                    Text(model.agentStatus?.loaded == true ? "Running" : "Not running")
                    Spacer()
                    if model.agentStatus?.installed == true {
                        Button("Remove") { model.uninstallAgent() }
                    } else {
                        Button("Install") { model.installAgent() }
                    }
                }
                CommitField(
                    title: "Check for due jobs every", prompt: "1h", value: automation.checkEvery.description,
                    validate: { Age.parse($0).map { AutomationSettings.checkEveryRange.contains($0.seconds) } ?? false }
                ) { value in
                    model.updateConfig { $0.automation.checkEvery = Age.parse(value)! }
                    if model.agentStatus?.installed == true { model.installAgent() }
                }
                Text("Between 5m and 24h.").font(.caption).foregroundStyle(.secondary)
                Toggle(
                    "Notifications",
                    isOn: Binding(
                        get: { automation.notifications }, set: { value in model.updateConfig { $0.automation.notifications = value } }))
            }
            Section("History") {
                Toggle(
                    "Weekly storage snapshot",
                    isOn: Binding(
                        get: { automation.snapshot != nil },
                        set: { on in
                            model.updateConfig {
                                $0.automation.snapshot = on ? .defaultSnapshot : nil
                            }
                        }))
                Text("A full analysis, used for “What grew?”. Runs in the background at low priority.").font(.caption).foregroundStyle(
                    .secondary)
            }
            Section("AI models") {
                CommitField(
                    title: "Count models as active if used within", prompt: "90d", value: automation.activeModelWindow.description,
                    validate: { Age.parse($0) != nil }
                ) { value in
                    model.updateConfig { $0.automation.activeModelWindow = Age.parse(value)! }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RulesSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        let disabled = Set(model.config.rules.disabled)
        // Show every built-in rule, including disabled ones, so they can be turned back on.
        let all = model.rulesIncludingDisabled()
        let visible =
            search.isEmpty
            ? all : all.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading) {
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            List(visible) { rule in
                Toggle(
                    isOn: Binding(
                        get: { !disabled.contains(rule.id) },
                        set: { on in
                            model.updateConfig { config in
                                if on { config.rules.disabled.removeAll { $0 == rule.id } } else { config.rules.disabled.append(rule.id) }
                            }
                        })
                ) {
                    HStack {
                        Text(rule.name)
                        Text(rule.group).foregroundStyle(.secondary)
                        Spacer()
                        SafetyBadge(level: rule.safety.level, compact: true)
                    }
                }
            }
            Text("Your own rules live in \(PathUtil.abbreviate(model.paths.userRulesDirectory)).").font(.caption).foregroundStyle(
                .secondary)
        }
        .padding()
    }
}

private struct ConfigFilePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let paths = model.paths
        VStack(alignment: .leading, spacing: 12) {
            Text("Everything here is stored as YAML, so you can keep it in your dotfiles and edit it by hand.")
                .foregroundStyle(.secondary)
            LabeledContent("Config", value: PathUtil.abbreviate(paths.configFile))
            LabeledContent("Your rules", value: PathUtil.abbreviate(paths.userRulesDirectory))
            LabeledContent("History & journal", value: PathUtil.abbreviate(paths.stateDirectory))
            if let error = model.configError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(Theme.critical)
            } else {
                Label(
                    model.configFileExists ? "Config is valid" : "No config file yet — using defaults",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(Theme.good)
            }
            ScrollView {
                Text((try? YAMLEncoder().encode(model.config)) ?? "")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                ConfigFileButtons()
                Button("Reveal in Finder") { model.reveal(paths.configFile) }
                Spacer()
                Button("Reload") { model.reloadContext() }
            }
        }
        .padding(20)
    }
}
