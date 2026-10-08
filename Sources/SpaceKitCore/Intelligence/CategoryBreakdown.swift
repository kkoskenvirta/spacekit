import Foundation

/// A coarse, human category of disk usage ("Developer", "Applications", "Documents", …).
public struct StorageCategory: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let name: String
    /// SF Symbol name for the app.
    public let symbol: String

    public static let developer = StorageCategory(id: "developer", name: "Developer", symbol: "hammer")
    public static let ai = StorageCategory(id: "ai", name: "AI Models", symbol: "brain")
    public static let applications = StorageCategory(id: "applications", name: "Applications", symbol: "square.grid.2x2")
    public static let documents = StorageCategory(id: "documents", name: "Documents", symbol: "doc.text")
    public static let downloads = StorageCategory(id: "downloads", name: "Downloads", symbol: "arrow.down.circle")
    public static let media = StorageCategory(id: "media", name: "Photos & Media", symbol: "photo.on.rectangle")
    public static let cloud = StorageCategory(id: "cloud", name: "iCloud & Cloud Storage", symbol: "icloud")
    public static let mail = StorageCategory(id: "mail", name: "Mail & Messages", symbol: "envelope")
    public static let caches = StorageCategory(id: "caches", name: "Caches", symbol: "archivebox")
    public static let trash = StorageCategory(id: "trash", name: "Trash", symbol: "trash")
    public static let system = StorageCategory(id: "system", name: "macOS", symbol: "apple.logo")
    public static let systemData = StorageCategory(id: "systemData", name: "System Data", symbol: "gearshape.2")
    public static let other = StorageCategory(id: "other", name: "Other", symbol: "ellipsis.circle")
    /// Used space the scan couldn't see: folders without access, file system metadata, other users' data.
    /// (Purgeable space, such as local Time Machine snapshots, isn't counted as used at all.)
    public static let hidden = StorageCategory(id: "hidden", name: "Not scanned", symbol: "eye.slash")

    public static let all: [StorageCategory] = [
        .developer, .ai, .applications, .documents, .downloads, .media, .cloud, .mail, .caches, .trash,
        .system, .systemData, .other, .hidden,
    ]

    public static func byID(_ id: String) -> StorageCategory { all.first { $0.id == id } ?? .other }
}

extension StorageCategory {
    /// The breakdown category of what a rule matched, from its dotted category (`developer.build`,
    /// `system.trash`, `personal.photos`, …). `nil` means the rule says nothing about the kind of data, so
    /// its location decides (credentials in `~/.ssh` stay "Other", in `~/Library` "System Data").
    public init?(ruleCategory: String) {
        let parts = ruleCategory.split(separator: ".", maxSplits: 1).map(String.init)
        let sub = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "developer": self = .developer
        case "ai": self = .ai
        case "cache": self = .caches
        case "system":
            switch sub {
            case "trash": self = .trash
            case "installers": self = .applications
            default: self = .systemData
            }
        case "personal":
            switch sub {
            case "downloads": self = .downloads
            case "photos", "backups": self = .media
            case "mail", "messages": self = .mail
            case "code": self = .developer
            default: return nil
            }
        default: return nil
        }
    }
}

public struct CategorySlice: Sendable, Identifiable, Hashable {
    public let category: StorageCategory
    public var size: UInt64
    public var id: String { category.id }
}

/// Attributes every scanned byte to exactly one category.
public enum CategoryBreakdown {
    /// Built-in locations. More specific paths win over their ancestors.
    public static func builtinLocations(home: String) -> [(String, StorageCategory)] {
        let h = home
        let toolHomes =
            ToolHomes.developer.map { (PathUtil.expand($0, home: h), StorageCategory.developer) }
            + ToolHomes.ai.map { (PathUtil.expand($0, home: h), StorageCategory.ai) }
        return toolHomes + [
            ("/Applications", .applications), ("\(h)/Applications", .applications),
            ("/System/Applications", .system), ("/System", .system), ("/usr", .system), ("/bin", .system), ("/sbin", .system),
            ("/private/var/vm", .system), ("/System/Volumes/VM", .system), ("/System/Volumes/Preboot", .system),
            ("/System/Volumes/Update", .system), ("/Library/Apple", .system),
            ("/Library", .systemData), ("/private", .systemData), ("/opt", .developer), ("/usr/local", .developer),
            ("/System/Volumes/Data", .systemData), ("/Library/Developer", .developer), ("/Library/Caches", .caches),
            ("/System/Library/Caches", .caches), ("/private/var/folders", .caches), ("/opt/homebrew", .developer),
            ("/Users", .other), ("\(h)", .other), ("\(h)/Library", .systemData),
            ("\(h)/Library/Developer", .developer), ("\(h)/Library/Android", .developer),
            ("\(h)/Library/Caches", .caches), ("\(h)/Library/Logs", .systemData),
            ("\(h)/Library/Mobile Documents", .cloud), ("\(h)/Library/CloudStorage", .cloud),
            ("\(h)/Library/Mail", .mail), ("\(h)/Library/Messages", .mail),
            ("\(h)/Library/Containers/com.apple.mail", .mail),
            ("\(h)/Library/Containers/com.docker.docker", .developer), ("\(h)/Library/Group Containers/HUC5ZSN4ZQ.com.docker", .developer),
            ("\(h)/Library/Application Support/MobileSync", .media),
            ("\(h)/Documents", .documents), ("\(h)/Desktop", .documents), ("\(h)/Downloads", .downloads),
            ("\(h)/Pictures", .media), ("\(h)/Movies", .media), ("\(h)/Music", .media),
            ("\(h)/.Trash", .trash),
            ("\(h)/Developer", .developer), ("\(h)/Projects", .developer), ("\(h)/projects", .developer),
            ("\(h)/code", .developer), ("\(h)/Code", .developer), ("\(h)/src", .developer), ("\(h)/dev", .developer),
            ("\(h)/repos", .developer), ("\(h)/workspace", .developer), ("\(h)/git", .developer), ("\(h)/GitHub", .developer),
            ("\(h)/.cache/huggingface", .ai), ("\(h)/.cache/lm-studio", .ai),
        ]
    }

    /// Path → category for the built-in locations and every folder a rule matched. A rule's category wins
    /// over the location (a `node_modules` in Documents is developer data); see `StorageCategory(ruleCategory:)`.
    public static func locations(home: String = PathUtil.home, findings: [Finding] = []) -> [String: StorageCategory] {
        var locations: [String: StorageCategory] = [:]
        for (path, category) in builtinLocations(home: home) { locations[path] = category }
        for finding in findings {
            guard let category = StorageCategory(ruleCategory: finding.rule.category) else { continue }
            for item in finding.items where item.kind == .directory { locations[item.path] = category }
        }
        return locations
    }

    /// The category of `path`'s nearest listed ancestor (or `path` itself), if any.
    public static func nearestCategory(for path: String, in locations: [String: StorageCategory]) -> StorageCategory? {
        var current = path
        while true {
            if let category = locations[current] { return category }
            if current == "/" || current.isEmpty { return nil }
            current = PathUtil.parent(current)
        }
    }

    /// Categorises a scan, attributing every byte to exactly one category (see `locations(home:findings:)`).
    public static func compute(tree: ScanTree, findings: [Finding] = [], home: String = PathUtil.home, capacity: VolumeCapacity? = nil)
        -> [CategorySlice]
    {
        let locations = locations(home: home, findings: findings)
        var ancestors = Set<String>()
        for path in locations.keys {
            var current = PathUtil.parent(path)
            while current != "/" && !current.isEmpty && ancestors.insert(current).inserted {
                current = PathUtil.parent(current)
            }
            ancestors.insert("/")
        }

        var totals: [String: UInt64] = [:]
        let anchors = tree.isMultiRoot ? tree.root.children : [tree.root]
        for anchor in anchors {
            let inherited = nearestCategory(for: anchor.path, in: locations) ?? .other
            var stack: [(DirNode, String, StorageCategory)] = [(anchor, anchor.path, inherited)]
            while let (node, path, current) = stack.popLast() {
                let category = locations[path] ?? current
                if ancestors.contains(path) {
                    totals[category.id, default: 0] &+= node.directFileSize
                    for child in node.children { stack.append((child, PathUtil.join(path, child.name), category)) }
                } else {
                    totals[category.id, default: 0] &+= node.size
                }
            }
        }

        let slices = totals.compactMap { id, size in size > 0 ? CategorySlice(category: .byID(id), size: size) : nil }
        if let capacity = capacity ?? tree.capacity, anchors.contains(where: { $0.path == "/" }) {
            return updatingHidden(slices, capacity: capacity, scannedBytes: tree.root.size)
        }
        return slices.sorted { $0.size > $1.size }
    }
}

extension CategoryBreakdown {
    /// Recomputes the "Not scanned" slice from a live capacity reading, so the breakdown keeps matching the
    /// disk as space is freed (only meaningful when the scan covered the whole startup disk).
    public static func updatingHidden(_ slices: [CategorySlice], capacity: VolumeCapacity, scannedBytes: UInt64) -> [CategorySlice] {
        var result = slices.filter { $0.category != .hidden }
        if capacity.used > scannedBytes {
            result.append(CategorySlice(category: .hidden, size: capacity.used - scannedBytes))
        }
        return result.sorted { $0.size > $1.size }
    }
}
