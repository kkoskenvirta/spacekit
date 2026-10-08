import SpaceKitCore
import SwiftUI

struct ExploreView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ExploreHeader()
            Divider()
            if let progress = model.progressSnapshot, model.isScanning {
                ScanningView(progress: progress)
            } else if let focus = model.focus, let tree = model.tree {
                HSplitView {
                    VStack(spacing: 10) {
                        if tree.stats.errors > 0 && !FullDiskAccess.isGranted {
                            FullDiskAccessBanner(unreadable: tree.stats.errors)
                        }
                        Breadcrumb()
                        DiskMapView(focus: focus, revision: model.treeRevision)
                            .id(focus.address)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        MapLegend()
                    }
                    .padding(16)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                    ExploreSidebar(focus: focus)
                        .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
                }
            } else {
                ExploreEmptyState()
            }
        }
        .navigationTitle("Explore")
        .navigationSubtitle(PathUtil.abbreviate(model.scanPath))
    }
}

// MARK: - Header

struct ExploreHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 16) {
            Menu {
                Section("Volumes") {
                    ForEach(model.volumes, id: \.mountPoint) { volume in
                        Button("\(volume.name) — \(volume.used.formattedBytes) of \(volume.total.formattedBytes)") { model.scan(volume.mountPoint) }
                    }
                }
                Section("Places") {
                    Button("Home Folder") { model.scan("~") }
                    Button("Library") { model.scan("~/Library") }
                    Button("Developer") { model.scan("~/Library/Developer") }
                }
                Divider()
                Button("Choose Folder…") { model.chooseFolder() }
            } label: {
                Label(scanTitle, systemImage: "internaldrive")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let capacity = model.scanCapacity ?? model.bootVolume {
                CapacitySummary(capacity: capacity).frame(maxWidth: 300, alignment: .leading)
            }

            Spacer()

            Picker("Visualization", selection: $model.visualization) {
                Label("Sectors", systemImage: "circle.circle").tag(UISettings.Visualization.sunburst)
                Label("Treemap", systemImage: "square.grid.3x3.square").tag(UISettings.Visualization.treemap)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Sectors (sunburst) or treemap")

            Picker("Color by", selection: $model.colorMode) {
                Text("Folder").tag(UISettings.ColorMode.branch)
                Text("Kind").tag(UISettings.ColorMode.category)
                Text("Safety").tag(UISettings.ColorMode.safety)
                Text("Age").tag(UISettings.ColorMode.age)
            }
            .fixedSize()

            Stepper("Depth \(model.mapDepth)", value: $model.mapDepth, in: 1...8).fixedSize()

            if model.isScanning {
                Button("Stop", systemImage: "stop.fill") { model.cancelScan() }
            } else {
                Button(model.tree == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise") { model.scan() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var scanTitle: String {
        let path = model.scanPath
        if path == "/" { return model.bootVolume?.name ?? "Macintosh HD" }
        return PathUtil.abbreviate(path)
    }
}

struct Breadcrumb: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless).disabled(!model.canGoBack).help("Back")
            .keyboardShortcut("[", modifiers: .command)
            Button {
                model.goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless).disabled(!model.canGoUp).help("Enclosing folder")
            .keyboardShortcut(.upArrow, modifiers: .command)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.breadcrumb.enumerated()), id: \.element.address) { index, node in
                        if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        Button(index == 0 ? PathUtil.abbreviate(node.name) : node.displayName) { model.focus = node }
                            .buttonStyle(.borderless)
                            .foregroundStyle(node === model.focus ? .primary : .secondary)
                    }
                }
            }
            Spacer()
            if let focus = model.focus {
                Text("\(focus.size.formattedBytes) · \(focus.fileCount.formatted()) files").font(.callout).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

struct MapLegend: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FlowLayout(spacing: 14, lineSpacing: 6) {
            switch model.colorMode {
            case .branch:
                Text("Colors follow the top-level folders; deeper rings are lighter. Double-click to zoom in.")
            case .category:
                ForEach(
                    [StorageCategory.developer, .applications, .ai, .documents, .media, .caches, .system, .systemData, .other], id: \.id
                ) { category in
                    legendItem(Theme.color(for: category), category.name)
                }
            case .safety:
                ForEach(SafetyLevel.allCases, id: \.self) { level in SafetyBadge(level: level) }
                legendItem(Theme.other, "Not recognised")
            case .age:
                Text("Last modified:")
                ForEach(Theme.ageBuckets, id: \.label) { bucket in legendItem(bucket.color, bucket.label) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label).fixedSize()
        }
    }
}

// MARK: - Sidebar list & inspector

struct ExploreSidebar: View {
    @Environment(AppModel.self) private var model
    let focus: DirNode

    var body: some View {
        VStack(spacing: 0) {
            if focus === model.tree?.root, !model.categories.isEmpty,
                model.scanPath == "/" || PathUtil.isAncestorOrEqual(model.scanPath, of: PathUtil.home)
            {
                CategoryBreakdownView(slices: model.categories, total: model.scanCapacity?.used ?? focus.size)
                    .padding(16)
                Divider()
            }
            ItemList(focus: focus)
            if let selection = model.selection?.diskItem {
                Divider()
                SelectionInspector(item: selection)
            }
        }
        .background(.background)
    }
}

struct CategoryBreakdownView: View {
    let slices: [CategorySlice]
    let total: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's on this disk").font(.headline)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(slices) { slice in
                        Rectangle().fill(Theme.color(for: slice.category))
                            .frame(width: max(2, proxy.size.width * CGFloat(slice.size) / CGFloat(max(total, 1)) - 2))
                            .help("\(slice.category.name): \(slice.size.formattedBytes)")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 12)
            ForEach(slices.prefix(8)) { slice in
                HStack {
                    Image(systemName: slice.category.symbol).frame(width: 18).foregroundStyle(Theme.color(for: slice.category))
                    Text(slice.category.name)
                    Spacer()
                    Text(slice.size.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                .help(
                    slice.category.id == StorageCategory.hidden.id
                        ? "Used space the scan couldn't see: folders without access (grant Full Disk Access), file system metadata, other users' files. Purgeable space isn't counted as used."
                        : "")
            }
        }
    }
}

struct ItemList: View {
    @Environment(AppModel.self) private var model
    let focus: DirNode

    var body: some View {
        let items = model.items(of: focus)
        let largest = Double(max(items.first?.size ?? 1, 1))
        List(
            selection: Binding(
                get: { model.selection?.id },
                set: { id in model.selection = items.first { $0.id == id }.map { .item($0) } }
            )
        ) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ItemRow(
                    item: item, fraction: Double(item.size) / largest, color: Theme.categorical(index), rule: model.rule(for: item.path)
                )
                .tag(item.id)
                .contextMenu { MapItemMenu(item: .item(item)) }
                .onTapGesture(count: 2) { if let directory = item.directory { model.open(directory) } }
                .simultaneousGesture(TapGesture().onEnded { model.selection = .item(item) })
            }
        }
        .listStyle(.inset)
        .onKeyPress(.return) {
            if let directory = model.selection?.directory {
                model.open(directory)
                return .handled
            }
            return .ignored
        }
    }
}

struct ItemRow: View {
    let item: DiskItem
    let fraction: Double
    let color: Color
    let rule: Rule?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(item.isDirectory ? color : .secondary).frame(width: 16)
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if let rule { SafetyBadge(level: rule.safety.level, compact: true) }
                Spacer()
                Text(item.size.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                Capsule().fill(color.opacity(0.85)).frame(width: max(3, proxy.size.width * fraction))
            }
            .frame(height: 4)
            switch item.note(rule: rule) {
            case .rule(let rule): Text(rule.name).font(.caption).foregroundStyle(.secondary)
            case .noAccess: Text("No access — needs Full Disk Access").font(.caption).foregroundStyle(Theme.warning)
            case .sameAs(let name): Text("Same folder as /\(name), counted there").font(.caption).foregroundStyle(.secondary)
            case .otherVolume: Text("Another volume").font(.caption).foregroundStyle(.secondary)
            case nil: EmptyView()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch item {
        case .directory(let node): return node.name.hasSuffix(".app") ? "app" : "folder.fill"
        case .file: return "doc"
        case .otherFiles: return "doc.on.doc"
        }
    }
}

struct SelectionInspector: View {
    @Environment(AppModel.self) private var model
    let item: DiskItem

    var body: some View {
        let rule = model.rule(for: item.path)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).font(.headline).lineLimit(2)
                Spacer()
                Text(item.size.formattedBytes).font(.title3.weight(.semibold)).monospacedDigit()
            }
            if let path = item.path {
                Text(PathUtil.abbreviate(path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            }
            if let rule {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(rule.name).font(.callout.weight(.semibold))
                        SafetyBadge(level: rule.safety.level)
                    }
                    if let description = rule.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                    if let recreatedBy = rule.recreatedBy {
                        Text("Recreated by: \(recreatedBy)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 12) {
                if let directory = item.directory {
                    Text("\(directory.fileCount.formatted()) files").foregroundStyle(.secondary)
                }
                if let modified = item.modified {
                    Text("Modified \(modified.relativeDescription())").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            HStack {
                Button("Reveal", systemImage: "magnifyingglass") { model.reveal(item.path) }
                if let cleanup = model.cleanupItem(for: item) {
                    Button("Add to List", systemImage: "plus.circle") { model.addToCleanupList([cleanup]) }
                        .disabled(model.isInCleanupList(item.path))
                    Button("Move to Trash…", systemImage: "trash", role: .destructive) {
                        model.review(CleanupPlan(items: [cleanup]), title: "Remove \(item.name)")
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
    }
}

// MARK: - Scanning & empty states

struct ScanningView: View {
    @Environment(AppModel.self) private var model
    let progress: ScanProgress.Snapshot

    var body: some View {
        HStack(spacing: 32) {
            if let scan = model.scanProgress {
                LiveScanMap(progress: scan).frame(width: 320, height: 320)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning \(PathUtil.abbreviate(model.scanPath))…").font(.title3.weight(.semibold))
                }
                Text(progress.bytes.formattedBytes).font(.system(size: 40, weight: .semibold)).monospacedDigit().contentTransition(
                    .numericText())
                Text("\(progress.files.formatted()) files · \(progress.directories.formatted()) folders").foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(PathUtil.abbreviate(progress.currentPath)).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(
                    .middle
                )
                .frame(maxWidth: 420, alignment: .leading)
                let listed = model.liveChildren.filter(\.isListed)
                if !listed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        let colorIndex = Dictionary(uniqueKeysWithValues: listed.enumerated().map { ($0.element.address, $0.offset) })
                        let children = listed.sorted { $0.liveSize > $1.liveSize }.prefix(6)
                        ForEach(children, id: \.address) { child in
                            HStack {
                                Circle().fill(Theme.categorical(colorIndex[child.address] ?? 99)).frame(width: 8, height: 8)
                                Text(child.name)
                                Spacer()
                                Text(child.liveSize.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                    .frame(maxWidth: 360)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ExploreEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "circle.circle").font(.system(size: 56)).foregroundStyle(Theme.categorical[0])
            Text("Where is my disk going?").font(.title.weight(.semibold))
            Text(
                "Scan your whole disk, hidden folders included, and see it as an interactive map.\nSpaceKit recognises developer and AI data and tells you what's safe to remove."
            )
            .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Button("Scan \(model.bootVolume?.name ?? "Startup Disk")") { model.scan("/") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Scan Home Folder") { model.scan("~") }.controlSize(.large)
                Button("Choose Folder…") { model.chooseFolder() }.controlSize(.large)
            }
            if !FullDiskAccess.isGranted {
                Label("Tip: grant Full Disk Access first so protected folders are included.", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
