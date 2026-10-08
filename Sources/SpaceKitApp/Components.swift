import AppKit
import SpaceKitCore
import SwiftUI

/// Icon + label + color, so safety is never conveyed by color alone.
struct SafetyBadge: View {
    let level: SafetyLevel
    var compact = false

    var body: some View {
        Label {
            Text(level.title)
        } icon: {
            Image(systemName: Theme.symbol(for: level)).foregroundStyle(Theme.color(for: level))
        }
        .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
        .font(.caption.weight(.medium))
        .help("\(level.title) — risk: \(level.risk)")
    }
}

struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// A headline number with a label — the "hero figure" pattern.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var symbol: String?
    var tint: Color?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(tint ?? .secondary) }
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(value).font(.system(size: 28, weight: .semibold)).contentTransition(.numericText())
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Used/total bar for a volume.
struct CapacityBar: View {
    let capacity: VolumeCapacity
    var height: CGFloat = 8

    var tint: Color {
        switch capacity.fullness {
        case .nearlyFull: return Theme.critical
        case .filling: return Theme.warning
        case .comfortable: return Theme.categorical[0]
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(tint).frame(width: max(height, proxy.size.width * capacity.usedFraction))
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(capacity.name): \(capacity.used.formattedBytes) of \(capacity.total.formattedBytes) used")
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.semibold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Card container used across sections.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
    }
}

/// Banner shown when scans can't see privacy-protected folders.
struct FullDiskAccessBanner: View {
    let unreadable: UInt64

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(unreadable) protected folders couldn't be read").font(.callout.weight(.semibold))
                Text(
                    "macOS hides Mail, Messages, Safari and other apps' data unless SpaceKit has Full Disk Access. Their space shows as Hidden."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
        }
        .padding(12)
        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Lays children out left to right, wrapping to new lines (for legends).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if extra > width && !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], extra, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// "Create Starter Config" and "Open in Editor", as onboarding and Settings show them.
struct ConfigFileButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Create Starter Config") { model.createStarterConfig() }
            .disabled(model.configFileExists)
        Button("Open in Editor") { model.openConfigInEditor() }
    }
}
