import Foundation

/// One model (or dataset, or cache) belonging to a local AI tool.
public struct AIModel: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case model, dataset, cache, orphaned }
    public var name: String
    public var kind: Kind
    public var size: UInt64
    public var lastUsed: Date?
    /// Files or folders that hold the model. For Ollama these are blobs that may be shared with other models.
    public var paths: [String]
    /// Preferred way to remove it, when the tool has one (e.g. `ollama rm llama3:8b`), from the rule's
    /// `ai.removeCommand`.
    public var removeCommand: [String]?
    public var ruleID: String
    /// The rule says this is regenerable (a true cache), not something you'd want back.
    public var isRegenerable: Bool = false
    /// `paths` may hold files other models use too (Ollama blobs), so only `removeCommand` may remove it.
    public var filesAreShared: Bool = false
    /// The findings' own items when `paths` alone would say too much: a folder's loose files (only the names
    /// counted) or the rest of a folder whose other entries belong to models or rules. Removal plans exactly these.
    public var items: [FindingItem] = []
    public var id: String { ruleID + ":" + name }

    /// Whether `CleanupPlan.removing(_:)` has anything to plan for it.
    public var isRemovable: Bool { removeCommand != nil || (!filesAreShared && !paths.isEmpty) }

    public func isActive(within window: Age, now: Date = Date()) -> Bool {
        guard let lastUsed else { return false }
        return now.timeIntervalSince(lastUsed) < window.seconds
    }
}

public struct AITool: Sendable, Identifiable {
    public var name: String
    public var models: [AIModel]
    public var id: String { name }
    public var size: UInt64 { models.reduce(0) { $0 &+ $1.size } }
}

/// The "AI Development" summary: how much local AI tooling uses, and how much of it is idle.
public struct AIReport: Sendable {
    public var tools: [AITool]
    public var activeWindow: Age

    public var total: UInt64 { tools.reduce(0) { $0 &+ $1.size } }
    private var models: [AIModel] { tools.flatMap(\.models) }

    /// Models used within the active window.
    public func active(now: Date = Date()) -> UInt64 {
        models.filter { $0.kind != .cache && $0.kind != .orphaned && $0.isActive(within: activeWindow, now: now) }
            .reduce(0) { $0 &+ $1.size }
    }

    /// Models not used within the active window.
    public func unused(now: Date = Date()) -> UInt64 {
        models.filter { ($0.kind == .model || $0.kind == .dataset) && !$0.isActive(within: activeWindow, now: now) }
            .reduce(0) { $0 &+ $1.size }
    }

    /// Regenerable caches, orphaned blobs and idle models: what could go without losing anything you're using.
    /// Caches that hold something you might want back (session transcripts, downloads) only count once idle.
    public func reclaimable(now: Date = Date()) -> UInt64 {
        models.filter { model in
            switch model.kind {
            case .orphaned: return true
            case .cache: return model.isRegenerable || !model.isActive(within: activeWindow, now: now)
            case .model, .dataset: return !model.isActive(within: activeWindow, now: now)
            }
        }
        .reduce(0) { $0 &+ $1.size }
    }
}

public enum AIInspector {
    /// Builds the AI report from findings of rules that carry an `ai:` block.
    public static func report(findings: [Finding], tree: ScanTree, activeWindow: Age = .days(90)) -> AIReport {
        var tools: [String: [AIModel]] = [:]
        var order: [String] = []
        for finding in findings {
            guard let ai = finding.rule.ai else { continue }
            if tools[ai.tool] == nil { order.append(ai.tool) }
            let models: [AIModel]
            switch ai.layout {
            case "ollama": models = ollamaModels(finding: finding)
            case "huggingface": models = huggingFaceModels(finding: finding, tree: tree)
            case "lmstudio": models = nestedModels(finding: finding, tree: tree, depth: 2)
            case "children": models = nestedModels(finding: finding, tree: tree, depth: 1)
            default:
                var cache = AIModel(
                    name: finding.rule.name, kind: .cache, size: finding.size, lastUsed: finding.lastUsed,
                    paths: finding.items.map(\.path), removeCommand: nil, ruleID: finding.rule.id)
                cache.items = finding.items
                models = [cache]
            }
            let regenerable = finding.rule.safety.level == .safe
            tools[ai.tool, default: []] += models.map { model in
                var model = model
                model.isRegenerable = regenerable
                return model
            }
        }
        let result = order.map { AITool(name: $0, models: tools[$0]!.sorted { $0.size > $1.size }) }
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
        return AIReport(tools: result, activeWindow: activeWindow)
    }

    // MARK: Ollama

    /// Reads Ollama's manifests (`models/manifests/<registry>/<namespace>/<model>/<tag>`) to size each model
    /// from the blobs it references. A blob several tags share is counted once, in a separate "Shared layers"
    /// entry, so the tool's total matches the disk. Blobs no manifest references are reported as orphaned,
    /// but only when every manifest could be read: otherwise an unreadable manifest's blobs would look unused.
    static func ollamaModels(finding: Finding) -> [AIModel] {
        finding.items.map(\.path)
            .filter { $0.hasSuffix("models") || FileManager.default.fileExists(atPath: $0 + "/manifests") }
            .flatMap { ollamaModels(root: $0, rule: finding.rule) }
    }

    private static func ollamaModels(root: String, rule: Rule) -> [AIModel] {
        let ruleID = rule.id
        let manifests = root + "/manifests"
        let blobs = root + "/blobs"
        guard let enumerator = FileManager.default.enumerator(atPath: manifests) else { return [] }
        var tags: [(name: String, layers: [(blob: String, size: UInt64)])] = []
        var references: [String: Int] = [:]
        var everyManifestRead = true
        while let relative = enumerator.nextObject() as? String {
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { continue }
            if PathUtil.lastComponent(relative).hasPrefix(".") { continue }
            guard let data = FileManager.default.contents(atPath: manifests + "/" + relative),
                let manifest = try? JSONDecoder().decode(OllamaManifest.self, from: data)
            else {
                everyManifestRead = false
                continue
            }
            var layers: [(blob: String, size: UInt64)] = []
            for layer in manifest.layers + [manifest.config].compactMap({ $0 }) {
                let blob = blobs + "/" + layer.digest.replacingOccurrences(of: ":", with: "-")
                guard !layers.contains(where: { $0.blob == blob }) else { continue }
                layers.append((blob, UInt64(max(0, layer.size))))
                references[blob, default: 0] += 1
            }
            guard let name = ollamaModelName(relative) else { continue }
            tags.append((name, layers))
        }

        var models: [AIModel] = []
        var shared: [String: UInt64] = [:]
        for tag in tags {
            var size: UInt64 = 0
            for layer in tag.layers {
                if references[layer.blob, default: 0] > 1 { shared[layer.blob] = layer.size } else { size &+= layer.size }
            }
            let blobPaths = tag.layers.map(\.blob)
            var model = AIModel(
                name: tag.name, kind: .model, size: size, lastUsed: newestAccess(blobPaths), paths: blobPaths,
                removeCommand: rule.ai?.removeArguments(forModel: tag.name), ruleID: ruleID)
            model.filesAreShared = true
            models.append(model)
        }
        if !shared.isEmpty {
            // No paths or command: removing shared blobs directly would break the models that use them.
            models.append(
                AIModel(
                    name: "Shared layers", kind: .model, size: shared.values.reduce(0, &+), lastUsed: newestAccess(Array(shared.keys)),
                    paths: [], removeCommand: nil, ruleID: ruleID))
        }
        if everyManifestRead, let orphans = unreferencedBlobs(in: blobs, referenced: references, ruleID: ruleID) {
            models.append(orphans)
        }
        return models
    }

    /// `registry.ollama.ai/library/llama3/8b` → `llama3:8b`; other namespaces and registries stay in the name.
    private static func ollamaModelName(_ relative: String) -> String? {
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        let tag = parts[parts.count - 1]
        let model = parts[parts.count - 2]
        let namespace = parts[parts.count - 3]
        let registry = parts.count >= 4 ? parts[parts.count - 4] : "registry.ollama.ai"
        var name = namespace == "library" ? model : "\(namespace)/\(model)"
        if registry != "registry.ollama.ai" { name = "\(registry)/\(name)" }
        return name + ":" + tag
    }

    private static func unreferencedBlobs(in blobs: String, referenced: [String: Int], ruleID: String) -> AIModel? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: blobs) else { return nil }
        let paths = names.map { blobs + "/" + $0 }.filter { referenced[$0] == nil && !$0.hasSuffix("-partial") }.sorted()
        let size = paths.reduce(UInt64(0)) { $0 &+ (FileSize.allocated(atPath: $1) ?? 0) }
        guard size > 0 else { return nil }
        return AIModel(name: "Unreferenced blobs", kind: .orphaned, size: size, lastUsed: nil, paths: paths, removeCommand: nil, ruleID: ruleID)
    }

    private static func newestAccess(_ paths: [String]) -> Date? {
        paths.compactMap(accessDate).max()
    }

    private struct OllamaManifest: Decodable {
        struct Layer: Decodable {
            var digest: String
            var size: Int64
        }
        var layers: [Layer]
        var config: Layer?
    }

    // MARK: Hugging Face

    /// `hub/models--org--name` → `org/name`.
    static func huggingFaceModels(finding: Finding, tree: ScanTree) -> [AIModel] {
        var models: [AIModel] = []
        for item in finding.items {
            guard item.kind == .directory, let node = tree.node(at: item.path) else {
                models.append(itemModel(item, kind: .cache, rule: finding.rule))
                continue
            }
            let hub = node.child(named: "hub") ?? node
            var rest: [FindingItem] = []
            for child in hub.children where child.size > 0 {
                let parts = child.name.components(separatedBy: "--")
                guard parts.count >= 2, ["models", "datasets", "spaces"].contains(parts[0]) else {
                    rest.append(RuleEngine.item(for: child, markers: tree.markers))
                    continue
                }
                let name = parts.dropFirst().joined(separator: "/")
                models.append(
                    AIModel(
                        name: name, kind: parts[0] == "datasets" ? .dataset : .model, size: child.size,
                        lastUsed: accessOrModified(child), paths: [child.path], removeCommand: nil, ruleID: finding.rule.id))
            }
            if hub !== node {
                rest += node.children.filter { $0 !== hub && $0.size > 0 }.map { RuleEngine.item(for: $0, markers: tree.markers) }
                rest += [RuleEngine.looseFilesItem(of: node)].compactMap { $0 }
            }
            rest += [RuleEngine.looseFilesItem(of: hub)].compactMap { $0 }
            let size = rest.reduce(UInt64(0)) { $0 &+ $1.size }
            if size > 0 {
                // The folder minus its models: only its other entries go, never the folder holding the models.
                var cache = AIModel(
                    name: "\(PathUtil.lastComponent(item.path)) cache", kind: .cache, size: size, lastUsed: node.lastUsed,
                    paths: rest.map(\.path), removeCommand: nil, ruleID: finding.rule.id)
                cache.items = rest
                models.append(cache)
            }
        }
        return models
    }

    /// A finding item that isn't a whole folder (loose files, a single file) as a model of its own.
    private static func itemModel(_ item: FindingItem, kind: AIModel.Kind, rule: Rule) -> AIModel {
        var model = AIModel(
            name: item.name, kind: kind, size: item.size, lastUsed: item.lastUsed, paths: [item.path], removeCommand: nil, ruleID: rule.id)
        model.items = [item]
        return model
    }

    // MARK: Folder-per-model layouts

    /// Each folder `depth` levels below the rule's path is a model (`publisher/model` for LM Studio).
    static func nestedModels(finding: Finding, tree: ScanTree, depth: Int) -> [AIModel] {
        var models: [AIModel] = []
        for item in finding.items {
            guard item.kind == .directory, let node = tree.node(at: item.path) else {
                models.append(itemModel(item, kind: .model, rule: finding.rule))
                continue
            }
            var level: [(DirNode, String)] = [(node, "")]
            for _ in 0..<depth {
                level = level.flatMap { parent, prefix in
                    parent.children.filter { $0.size > 0 }.map { ($0, prefix.isEmpty ? $0.name : prefix + "/" + $0.name) }
                }
            }
            if level.isEmpty {
                models.append(
                    AIModel(
                        name: item.name, kind: .model, size: item.size, lastUsed: item.lastUsed,
                        paths: [item.path], removeCommand: nil, ruleID: finding.rule.id))
            }
            for (child, name) in level {
                models.append(
                    AIModel(
                        name: name, kind: .model, size: child.size, lastUsed: accessOrModified(child),
                        paths: [child.path], removeCommand: nil, ruleID: finding.rule.id))
            }
        }
        return models
    }

    // MARK: Helpers

    /// Model weights are read, not written, when used, so access time is the better signal.
    private static func accessOrModified(_ node: DirNode) -> Date? {
        let newest = max(node.subtreeNewestAccessed, node.subtreeNewestModified)
        return newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil
    }

    private static func accessDate(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let newest = max(st.st_atimespec.tv_sec, st.st_mtimespec.tv_sec)
        return Date(timeIntervalSince1970: TimeInterval(newest))
    }
}
