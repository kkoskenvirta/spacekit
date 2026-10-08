import SpaceKitCore
import SwiftUI

/// Precomputed geometry and colors for one map, so hover and selection only repaint.
struct MapGeometry: Sendable {
    /// The layout key this geometry was computed for.
    var key = ""
    var arcs: [SunburstArc] = []
    var cells: [TreemapCell] = []
    var colors: [Color] = []
    var size: CGSize = .zero
}

/// Resolves the color of a map item for the current color mode. Memoizes per folder, so create one per layout pass.
final class MapColorer: @unchecked Sendable {
    let mode: UISettings.ColorMode
    let rules: RuleLookupCache
    let locations = CategoryBreakdown.locations(home: PathUtil.home)
    private var categoryCache: [String: StorageCategory] = [:]

    init(mode: UISettings.ColorMode, ruleIndex: RuleIndex) {
        self.mode = mode
        self.rules = RuleLookupCache(index: ruleIndex)
    }

    func color(item: MapItem, branch: Int, depth: Int) -> Color {
        if case .remainder = item { return Theme.other.opacity(0.6) }
        let base: Color
        switch mode {
        case .branch:
            base = Theme.categorical(branch)
        case .safety:
            if let path = item.path, let rule = rules.rule(containing: path) {
                base = Theme.color(for: rule.safety.level)
            } else {
                base = Theme.other
            }
        case .age:
            return Theme.ageColor(item.diskItem?.modified)
        case .category:
            base = Theme.color(for: category(of: item))
        }
        // Deeper levels recede toward the surface so the branch structure reads at a glance.
        return base.opacity(max(0.42, 1.0 - Double(depth) * 0.16))
    }

    func category(of item: MapItem) -> StorageCategory {
        guard let path = item.path else { return .other }
        if let rule = rules.rule(containing: path), let category = StorageCategory(ruleCategory: rule.category) { return category }
        if let cached = categoryCache[path] { return cached }
        let result = CategoryBreakdown.nearestCategory(for: path, in: locations) ?? .other
        categoryCache[path] = result
        return result
    }
}

struct DiskMapView: View {
    @Environment(AppModel.self) private var model
    let focus: DirNode
    let revision: Int

    @State private var geometry = MapGeometry()
    @State private var viewSize: CGSize = .zero

    /// The current geometry is for the other visualization, so it can't be drawn.
    private var isStale: Bool {
        model.visualization == .sunburst ? geometry.arcs.isEmpty : geometry.cells.isEmpty
    }

    private var key: String {
        "\(focus.address)-\(model.visualization)-\(model.colorMode)-\(model.mapDepth)-\(Int(viewSize.width))x\(Int(viewSize.height))-\(revision)"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    switch model.visualization {
                    case .sunburst: drawSunburst(&context, size: size)
                    case .treemap: drawTreemap(&context, size: size)
                    }
                }
                if model.visualization == .sunburst { centerLabel(size: proxy.size) }
                if geometry.key != key && (geometry.arcs.isEmpty && geometry.cells.isEmpty || isStale) {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): model.hovered = hit(location, size: proxy.size)
                case .ended: model.hovered = nil
                }
            }
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                if let item = hit(location, size: proxy.size), let directory = item.directory {
                    withAnimation(.easeOut(duration: 0.2)) { model.open(directory) }
                } else if model.visualization == .sunburst, isInCenter(location, size: proxy.size) {
                    withAnimation(.easeOut(duration: 0.2)) { model.goUp() }
                }
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { location in
                if let item = hit(location, size: proxy.size) {
                    model.selection = item
                } else if model.visualization == .sunburst, isInCenter(location, size: proxy.size) {
                    withAnimation(.easeOut(duration: 0.2)) { model.goUp() }
                }
            }
            .contextMenu { MapItemMenu(item: model.hovered ?? model.selection) }
            .onAppear { viewSize = proxy.size }
            .onChange(of: proxy.size) { _, size in viewSize = size }
            .task(id: key) { await relayout() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Disk map of \(focus.displayName), \(focus.size.formattedBytes)")
            .accessibilityHint("The list beside the map shows the same items.")
        }
    }

    // MARK: Layout

    private func relayout() async {
        let size = viewSize
        guard size.width > 20, size.height > 20 else { return }
        let focus = self.focus
        let visualization = model.visualization
        let depth = model.mapDepth
        let colorer = MapColorer(mode: model.colorMode, ruleIndex: model.ruleIndex)
        let key = self.key
        // The read begins here, on the main actor, where the workspace's changes run: none can land between this
        // check and the layout. This view may have been built before a change took its folder out of the tree (the
        // model has moved on to the survivor); that folder's parents may already be freed, so it isn't laid out.
        let lease = model.workspace.beginRead()
        guard focus === model.focus else {
            lease.end()
            return
        }
        let layout = await Task.detached(priority: .userInitiated) {
            defer { lease.end() }
            var geometry = MapGeometry(key: key, size: size)
            switch visualization {
            case .sunburst:
                geometry.arcs = Sunburst.layout(focus, maxRings: depth, minSweep: 0.004)
                geometry.colors = geometry.arcs.map { colorer.color(item: $0.item, branch: $0.branch, depth: $0.ring - 1) }
            case .treemap:
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                geometry.cells = Treemap.layout(focus, in: rect, maxDepth: depth, minCellArea: 36, padding: 2, headerHeight: 16)
                geometry.colors = geometry.cells.map { colorer.color(item: $0.item, branch: $0.branch, depth: $0.depth) }
            }
            return geometry
        }.value
        guard !Task.isCancelled else { return }
        geometry = layout
    }

    // MARK: Sunburst

    private func sunburstMetrics(_ size: CGSize) -> (center: CGPoint, inner: CGFloat, ring: CGFloat) {
        let radius = min(size.width, size.height) / 2 - 6
        let inner = radius * 0.24
        return (CGPoint(x: size.width / 2, y: size.height / 2), inner, (radius - inner) / CGFloat(max(model.mapDepth, 1)))
    }

    private func arcPath(_ arc: SunburstArc, center: CGPoint, inner: CGFloat, ring: CGFloat) -> Path {
        let r0 = inner + CGFloat(arc.ring - 1) * ring
        // Layout angles start at 12 o'clock; SwiftUI's start at 3 o'clock.
        return annularSector(
            center: center, inner: r0, outer: r0 + ring, start: .radians(arc.startAngle - .pi / 2), end: .radians(arc.endAngle - .pi / 2))
    }

    private func drawSunburst(_ context: inout GraphicsContext, size: CGSize) {
        let (center, inner, ring) = sunburstMetrics(size)
        let hoveredID = model.hovered?.id
        let selectedID = model.selection?.id
        for (index, arc) in geometry.arcs.enumerated() {
            let path = arcPath(arc, center: center, inner: inner, ring: ring)
            var color = geometry.colors.indices.contains(index) ? geometry.colors[index] : Theme.other
            if arc.id == hoveredID { color = color.opacity(0.75) }
            context.fill(path, with: .color(color))
            context.stroke(path, with: .color(Theme.surface), lineWidth: 1)
            if arc.id == selectedID {
                context.stroke(path, with: .color(.primary), lineWidth: 2)
            }
        }
        // Direct labels on the first ring where there's room (identity never relies on color alone).
        for arc in geometry.arcs where arc.ring == 1 {
            let radius = inner + ring * 0.5
            let arcLength = CGFloat(arc.sweep) * radius
            guard arcLength > 70, ring > 26 else { continue }
            let angle = arc.midAngle - .pi / 2
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            let text = Text(arc.item.name).font(.caption2.weight(.semibold)).foregroundStyle(.white)
            var label = context
            label.addFilter(.shadow(color: .black.opacity(0.45), radius: 1.5))
            label.draw(text, at: point)
        }
    }

    private func isInCenter(_ point: CGPoint, size: CGSize) -> Bool {
        let (center, inner, _) = sunburstMetrics(size)
        return hypot(point.x - center.x, point.y - center.y) < inner
    }

    private func centerLabel(size: CGSize) -> some View {
        let (_, inner, _) = sunburstMetrics(size)
        let shown = model.hovered
        return VStack(spacing: 2) {
            Text(shown?.name ?? focus.displayName).font(.headline).lineLimit(2).multilineTextAlignment(.center)
            Text((shown?.size ?? focus.size).formattedBytes).font(.title3.weight(.semibold)).monospacedDigit()
            if shown == nil, focus.parent != nil {
                Text("Click to go up").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: inner * 1.7)
        .allowsHitTesting(false)
    }

    // MARK: Treemap

    private func drawTreemap(_ context: inout GraphicsContext, size: CGSize) {
        let hoveredID = model.hovered?.id
        let selectedID = model.selection?.id
        for (index, cell) in geometry.cells.enumerated() {
            let rect = cell.rect.insetBy(dx: 0.5, dy: 0.5)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            let shape = Path(roundedRect: rect, cornerRadius: min(4, rect.width / 4, rect.height / 4))
            var color = geometry.colors.indices.contains(index) ? geometry.colors[index] : Theme.other
            if cell.id == hoveredID { color = color.opacity(0.75) }
            context.fill(shape, with: .color(color))
            if cell.depth == 0 {
                // A soft top-left highlight gives top-level blocks a cushion feel without hiding structure.
                context.fill(
                    shape,
                    with: .linearGradient(
                        Gradient(colors: [.white.opacity(0.14), .clear]),
                        startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            }
            if cell.id == selectedID {
                context.stroke(shape, with: .color(.primary), lineWidth: 2)
            }
            let isParent = cell.item.directory.map { !$0.children.isEmpty } ?? false
            let showsLabel = rect.width > 54 && rect.height > 18 && (cell.depth == 0 || !isParent || rect.height > 40)
            if showsLabel {
                let label = Text("\(cell.item.name)  \(Text(cell.item.size.formattedBytes).foregroundStyle(.white.opacity(0.8)))")
                    .font(cell.depth == 0 ? .caption.weight(.semibold) : .caption2)
                    .foregroundStyle(.white)
                var labelContext = context
                labelContext.clip(to: Path(rect.insetBy(dx: 3, dy: 1)))
                labelContext.addFilter(.shadow(color: .black.opacity(0.4), radius: 1))
                labelContext.draw(label, at: CGPoint(x: rect.minX + 5, y: rect.minY + 3), anchor: .topLeading)
            }
        }
    }

    // MARK: Hit testing

    private func hit(_ point: CGPoint, size: CGSize) -> MapItem? {
        switch model.visualization {
        case .sunburst:
            let (center, inner, ring) = sunburstMetrics(size)
            return Sunburst.hitTest(geometry.arcs, at: point, center: center, innerRadius: inner, ringWidth: ring)?.item
        case .treemap:
            return Treemap.hitTest(geometry.cells, at: point)?.item
        }
    }
}

/// A ring segment between two radii, from `start` to `end` clockwise on screen.
private func annularSector(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Angle, end: Angle) -> Path {
    var path = Path()
    path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
    path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
    path.closeSubpath()
    return path
}

/// Progressive map while a scan runs: top-level folders grow as their sizes come in.
struct LiveScanMap: View {
    let progress: ScanProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            Canvas { context, size in
                // Colors follow listing order, which never changes, so sectors don't repaint as sizes come in.
                let children = progress.liveChildren.filter(\.isListed)
                let total = Double(max(children.reduce(0) { $0 + $1.liveSize }, 1))
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = min(size.width, size.height) / 2 - 6
                let inner = outer * 0.55
                var angle = -Double.pi / 2
                for (index, child) in children.enumerated() where child.liveSize > 0 {
                    let sweep = Double(child.liveSize) / total * 2 * .pi
                    let path = annularSector(
                        center: center, inner: inner, outer: outer, start: .radians(angle), end: .radians(angle + sweep))
                    context.fill(path, with: .color(Theme.categorical(index).opacity(0.85)))
                    context.stroke(path, with: .color(Theme.surface), lineWidth: 1)
                    angle += sweep
                }
            }
        }
    }
}

/// Actions for an item in the map or list.
struct MapItemMenu: View {
    @Environment(AppModel.self) private var model
    let item: MapItem?

    var body: some View {
        if let item, let disk = item.diskItem {
            if let directory = disk.directory, !directory.children.isEmpty {
                Button("Open") { model.open(directory) }
            }
            Button("Reveal in Finder") { model.reveal(disk.path) }
            Divider()
            if let cleanup = model.cleanupItem(for: disk) {
                Button(model.isInCleanupList(disk.path) ? "Already in Cleanup List" : "Add to Cleanup List") {
                    model.addToCleanupList([cleanup])
                }
                .disabled(model.isInCleanupList(disk.path))
                Button("Move to Trash…") {
                    model.review(CleanupPlan(items: [cleanup]), title: "Remove \(disk.name)")
                }
            }
            if let path = disk.path, disk.isDirectory {
                Button("Automate Cleanup of This Folder…") { model.jobDraft = JobDraft(paths: [path]) }
            }
        }
    }
}
