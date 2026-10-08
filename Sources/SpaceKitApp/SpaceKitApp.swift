import AppKit
import SpaceKitCore
import SwiftUI

@main
struct SpaceKitApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("SpaceKit", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Startup Disk") { model.scan("/") }.keyboardShortcut("1", modifiers: [.command, .shift])
                Button("Scan Home Folder") { model.scan("~") }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Choose Folder to Scan…") { model.chooseFolder() }.keyboardShortcut("o")
                Divider()
                Button("Rescan") { model.scan() }.keyboardShortcut("r")
            }
            CommandMenu("Go") {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Divider()
                Button("Back") { model.goBack() }.keyboardShortcut("[").disabled(!model.canGoBack)
                Button("Enclosing Folder") { model.goUp() }.keyboardShortcut(.upArrow).disabled(!model.canGoUp)
            }
            CommandGroup(replacing: .help) {
                Button("Setup Guide") { model.showOnboarding = true }
                Button("Safety Guidelines") { model.showSafety = true }
            }
        }

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            Image(systemName: "internaldrive")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's model, so quitting can wait for a cleanup in progress.
    static weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched from `swift run` (no bundle), become a regular foreground app with a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting mid-cleanup would stop between two removals, so it waits until the cleanup finishes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppDelegate.model, model.isCleaning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A cleanup is still running"
        alert.informativeText = "SpaceKit can quit as soon as it finishes. Every removal is journaled as it happens."
        alert.addButton(withTitle: "Quit When Finished")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        // The cleanup may have finished while the alert was open.
        guard model.isCleaning else { return .terminateNow }
        model.quitWhenCleanupsAreDone()
        return .terminateLater
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.configError { ConfigErrorBanner(error: error) }
                Group {
                    switch model.section {
                    case .explore: ExploreView()
                    case .dev: DevIntelligenceView()
                    case .ai: AIView()
                    case .automation: AutomationView()
                    case .history: HistoryView()
                    case .rules: RulesView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $model.pendingCleanup) { pending in
            CleanupSheet(pending: pending)
        }
        .sheet(item: $model.jobDraft) { draft in
            JobEditor(draft: draft)
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
        }
        .sheet(isPresented: $model.showSafety) {
            SafetySheet()
        }
        .alert("SpaceKit", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            #if DEBUG
                DebugAutomation.start(model: model)
            #endif
            if model.tree == nil && !model.showOnboarding { model.scan() }
        }
    }
}

/// Stays above every section while the config file is invalid: cleaning is refused until it's fixed, and
/// nothing else on screen would say why.
struct ConfigErrorBanner: View {
    @Environment(AppModel.self) private var model
    let error: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.critical)
            VStack(alignment: .leading, spacing: 2) {
                Text("The config file is invalid, so SpaceKit won't clean anything.").font(.callout.weight(.semibold))
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Fix it (spacekit config validate shows the problem), then Reload.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Config") { model.openConfigInEditor() }
            Button("Reload") { model.reloadContext() }
        }
        .padding(10)
        .background(Theme.critical.opacity(0.12))
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })) {
                ForEach(AppSection.allCases) { section in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.title)
                            Text(section.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: section.symbol)
                    }
                    .badge(badge(for: section))
                    .tag(section)
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 10) {
                if !model.cleanupList.isEmpty {
                    CleanupListButton()
                }
                if let trash = model.trashBytes, trash > 0 {
                    Button {
                        model.emptyTrash()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            VStack(alignment: .leading) {
                                Text("Trash").font(.caption.weight(.semibold))
                                Text("\(trash.formattedBytes) still on disk").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Empty…").font(.caption)
                        }
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Moved items keep using space until the Trash is emptied")
                }
                if let capacity = model.bootVolume {
                    CapacitySummary(capacity: capacity, compact: true, showsName: true)
                }
            }
            .padding(12)
        }
    }

    private func badge(for section: AppSection) -> Text? {
        switch section {
        case .dev:
            guard let analysis = model.analysis else { return nil }
            let safe = analysis.total(.safe)
            return safe > 0 ? Text(safe.formattedBytes) : nil
        case .automation:
            return model.suggestions.isEmpty ? nil : Text("\(model.suggestions.count)")
        default:
            return nil
        }
    }
}

/// The "cleanup list": items gathered from Explore and Dev Intelligence for one combined review.
struct CleanupListButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack {
                Image(systemName: "tray.full")
                VStack(alignment: .leading) {
                    Text("Cleanup List").font(.caption.weight(.semibold))
                    Text("\(model.cleanupList.count) items · \(model.cleanupListBytes.formattedBytes)").font(.caption2).foregroundStyle(
                        .secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            CleanupListPopover(dismiss: { showing = false })
        }
    }
}

struct CleanupListPopover: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanup List").font(.headline)
            List {
                ForEach(model.cleanupList) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.name).lineLimit(1)
                            Text(PathUtil.abbreviate(item.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(
                                .middle)
                        }
                        Spacer()
                        Text(item.size.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                        Button {
                            model.cleanupList.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 420, height: 260)
            HStack {
                Button("Clear") { model.cleanupList = [] }
                Button("Automate These Folders…") {
                    model.jobDraft = JobDraft(paths: model.cleanupList.filter { $0.kind == .directory }.map(\.path))
                    dismiss()
                }
                .disabled(!model.cleanupList.contains { $0.kind == .directory })
                Spacer()
                Button("Review & Clean \(model.cleanupListBytes.formattedBytes)") {
                    model.review(CleanupPlan(items: model.cleanupList), title: "Clean \(model.cleanupList.count) items")
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

/// Compact status in the menu bar: free space, next job, pending suggestions.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let capacity = model.bootVolume {
                CapacitySummary(capacity: capacity, showsName: true)
                Text("\(capacity.used.formattedBytes) of \(capacity.total.formattedBytes) used").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if let next = model.jobRunner.nextRuns().first {
                Label("Next: \(next.job.name), \(next.date.relativeDescription())", systemImage: "clock").font(.callout)
            }
            if model.recovered90Days > 0 {
                Label("Recovered \(model.recovered90Days.formattedBytes) in 3 months", systemImage: "arrow.uturn.backward.circle").font(.callout)
            }
            if !model.suggestions.isEmpty {
                Button {
                    model.section = .automation
                    openWindow(id: "main")
                    NSApp.activate()
                } label: {
                    Label(
                        "\(model.suggestions.count) cleanup\(model.suggestions.count == 1 ? "" : "s") waiting for approval",
                        systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.link)
            }
            Divider()
            HStack {
                Button("Open SpaceKit") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            model.refreshVolumes()
            model.refreshAutomation()
        }
    }
}
