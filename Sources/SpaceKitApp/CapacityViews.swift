import AppKit
import SpaceKitCore
import SwiftUI

/// Disk capacity, shown the way Finder counts it: "available" includes purgeable space.
/// The detail line splits that into what's free right now and what macOS will release on demand.
struct CapacitySummary: View {
    @Environment(AppModel.self) private var model
    let capacity: VolumeCapacity
    var compact = false
    var showsName = false
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if showsName { Text(capacity.name).font(compact ? .caption.weight(.semibold) : .headline) }
                if showsName { Spacer() }
                Text("\(capacity.available.formattedBytes) available")
                    .font(compact ? .caption.weight(showsName ? .regular : .semibold) : .callout.weight(.semibold))
                    .foregroundStyle(showsName ? .secondary : .primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if !showsName {
                    Text("of \(capacity.total.formattedBytes)").font(.caption).foregroundStyle(.secondary)
                }
            }
            CapacityBar(capacity: capacity, height: compact ? 5 : 6)
            if capacity.purgeable > 1_000_000_000 || (model.trashBytes ?? 0) > 1_000_000_000 {
                Button {
                    showingDetails.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(detailLine).lineLimit(1)
                        Image(systemName: "info.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Why free space and available space differ")
                .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                    CapacityDetails(capacity: capacity).environment(model)
                }
            }
        }
        .animation(.default, value: capacity)
    }

    private var detailLine: String {
        var parts: [String] = ["\(capacity.freeNow.formattedBytes) free now"]
        if capacity.purgeable > 0 { parts.append("\(capacity.purgeable.formattedBytes) purgeable") }
        if let trash = model.trashBytes, trash > 1_000_000_000 { parts.append("\(trash.formattedBytes) in Trash") }
        return parts.joined(separator: " · ")
    }
}

/// Explains where "missing" free space is, with the actions that release it.
struct CapacityDetails: View {
    @Environment(AppModel.self) private var model
    let capacity: VolumeCapacity
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(capacity.name).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Available (as Finder shows it)", capacity.available.formattedBytes, bold: true)
                row("Free right now", capacity.freeNow.formattedBytes)
                row("Purgeable", capacity.purgeable.formattedBytes)
                row("Used", "\(capacity.used.formattedBytes) of \(capacity.total.formattedBytes)")
                if let trash = model.trashBytes { row("In the Trash", trash.formattedBytes) }
            }
            .font(.callout)

            if capacity.purgeable > 0 {
                Divider()
                Text("Purgeable space is released automatically when an app needs it.").font(.callout)
                if model.localSnapshotCount > 0 {
                    Text(
                        "This disk has \(model.localSnapshotCount) local Time Machine snapshot\(model.localSnapshotCount == 1 ? "" : "s"). Files deleted after a snapshot was taken stay referenced by it, so their space shows up here as purgeable until macOS thins the snapshots (usually within 24 hours). Your Time Machine backup disk isn't affected."
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("To release it right away, run this in Terminal:").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(LocalSnapshots.thinCommand()).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(LocalSnapshots.thinCommand(), forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if let trash = model.trashBytes, trash > 0 {
                Divider()
                HStack {
                    Text("Items in the Trash still use space until it's emptied.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Empty Trash…") { model.emptyTrash() }.controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func row(_ title: String, _ value: String, bold: Bool = false) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fontWeight(bold ? .semibold : .regular)
        }
    }
}
