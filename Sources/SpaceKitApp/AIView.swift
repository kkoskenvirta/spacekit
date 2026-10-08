import SpaceKitCore
import SwiftUI

/// Local AI storage: models, hubs and caches, split into active and idle.
struct AIView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionTitle(
                    title: "AI Development",
                    subtitle:
                        "Local models are huge and every tool keeps its own store. Not all of it is junk; this shows what you actually use."
                )
                if let report = model.aiReport {
                    if report.total == 0 {
                        ContentUnavailableView(
                            "No local AI storage found", systemImage: "cpu",
                            description: Text(
                                "SpaceKit looks for Ollama, Hugging Face, LM Studio, MLX, PyTorch, Whisper and AI coding tools."))
                    } else {
                        summary(report)
                        ForEach(report.tools) { tool in ToolCard(tool: tool, window: report.activeWindow) }
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Looking for local models…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(24)
        }
        .navigationTitle("AI Development")
    }

    private func summary(_ report: AIReport) -> some View {
        let days = Int(report.activeWindow.days)
        return HStack(spacing: 12) {
            StatTile(
                title: "AI storage", value: report.total.formattedBytes, detail: "\(report.tools.count) tools", symbol: "cpu",
                tint: Theme.categorical[2])
            StatTile(
                title: "Potentially reclaimable", value: report.reclaimable().formattedBytes, detail: "Caches, orphaned blobs, idle models",
                symbol: "arrow.down.circle", tint: Theme.good)
            StatTile(
                title: "Actively using", value: report.active().formattedBytes, detail: "Used in the last \(days) days",
                symbol: "bolt.circle", tint: Theme.categorical[0])
            StatTile(
                title: "Unused \(days)+ days", value: report.unused().formattedBytes, detail: "Candidates to remove",
                symbol: "moon.zzz", tint: Theme.warning)
        }
    }
}

private struct ToolCard: View {
    @Environment(AppModel.self) private var model
    let tool: AITool
    let window: Age

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(tool.name).font(.headline)
                    Spacer()
                    Text(tool.size.formattedBytes).font(.title3.weight(.semibold)).monospacedDigit()
                }
                Table(tool.models) {
                    TableColumn("Model") { model in
                        HStack(spacing: 6) {
                            Image(systemName: icon(model.kind)).foregroundStyle(.secondary)
                            Text(model.name).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    TableColumn("Size") { model in Text(model.size.formattedBytes).monospacedDigit() }
                        .width(min: 70, ideal: 80, max: 100)
                    TableColumn("Status") { model in status(model) }
                        .width(min: 80, ideal: 90, max: 110)
                    TableColumn("Last used") { model in Text(model.lastUsed?.relativeDescription() ?? "—").foregroundStyle(.secondary) }
                        .width(min: 90, ideal: 110, max: 140)
                    TableColumn("") { item in
                        Button("Remove…") { remove(item) }
                            .controlSize(.small)
                            .disabled(!item.isRemovable)
                    }
                    .width(76)
                }
                .tableStyle(.inset)
                .frame(height: min(CGFloat(tool.models.count) * 26 + 32, 300))
            }
        }
    }

    @ViewBuilder
    private func status(_ model: AIModel) -> some View {
        switch model.status(within: window) {
        case .orphaned: Label("Orphaned", systemImage: "exclamationmark.circle").foregroundStyle(Theme.warning)
        case .cache: Label("Cache", systemImage: "archivebox").foregroundStyle(.secondary)
        case .active: Label("Active", systemImage: "bolt.fill").foregroundStyle(Theme.good)
        case .idle: Label("Idle", systemImage: "moon.zzz").foregroundStyle(Theme.warning)
        }
    }

    private func icon(_ kind: AIModel.Kind) -> String {
        switch kind {
        case .model: return "shippingbox"
        case .dataset: return "tablecells"
        case .cache: return "archivebox"
        case .orphaned: return "questionmark.folder"
        }
    }

    private func remove(_ item: AIModel) {
        guard let analysis = model.analysis, let plan = CleanupPlan.removing(item, scanStarted: analysis.scanStarted) else { return }
        model.review(plan, title: "Remove \(item.name)")
    }
}
