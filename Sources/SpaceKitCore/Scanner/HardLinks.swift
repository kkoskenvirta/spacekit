import Foundation

/// Identifies a file whatever name it's reached by.
struct HardLinkKey: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
}

/// One name of a multiply-linked file.
struct HardLink {
    let node: DirNode
    let name: String
    /// The file's bytes are counted under exactly one of its links; the others count as files of 0 bytes.
    var hasBytes: Bool
}

/// A file with several hard links in the tree.
struct HardLinkGroup {
    let size: UInt64
    let modified: Int64
    var links: [HardLink]

    /// The order that picks the link holding the bytes: folder path first, then name. A scan and an in-place update
    /// of the same disk must agree, whatever order the links were reached in.
    static func precedes(folder: String, name: String, folder other: String, name otherName: String) -> Bool {
        folder != other ? folder < other : name < otherName
    }

    /// The link that should hold the bytes, or `nil` if none is left.
    var ownerIndex: Int? { ownerIndex { $0.path } }

    /// `ownerIndex`, reading each link's folder path from `path` (which may remember them).
    func ownerIndex(path: (DirNode) -> String) -> Int? {
        guard links.count > 1 else { return links.indices.first }
        let folders: [String] = links.map { path($0.node) }
        return links.indices.min { a, b in
            HardLinkGroup.precedes(folder: folders[a], name: links[a].name, folder: folders[b], name: links[b].name)
        }
    }
}

/// Every multiply-linked file in a tree, indexed by the folders holding its links, so a tree update reaches only
/// the files linked from where it changes the tree.
struct HardLinkTable {
    private(set) var groups: [HardLinkKey: HardLinkGroup] = [:]
    /// Folder → link name → the file it names.
    private var byFolder: [DirNode: [String: HardLinkKey]] = [:]

    init(_ groups: [HardLinkKey: HardLinkGroup] = [:]) {
        self.groups = groups
        for (key, group) in groups { index(group.links, as: key) }
    }

    subscript(key: HardLinkKey) -> HardLinkGroup? { groups[key] }

    /// The hard links directly in `folder`, by name.
    func links(in folder: DirNode) -> [String: HardLinkKey] { byFolder[folder] ?? [:] }

    /// The folders at or under `top` that hold hard links, and the files they link to.
    func linkedFolders(under top: DirNode) -> (folders: Set<DirNode>, keys: Set<HardLinkKey>) {
        var folders: Set<DirNode> = []
        var keys: Set<HardLinkKey> = []
        func collect(_ folder: DirNode) {
            guard let names = byFolder[folder] else { return }
            folders.insert(folder)
            keys.formUnion(names.values)
        }
        // Walk whichever is smaller: the subtree, or the folders holding links.
        if UInt64(byFolder.count) <= top.dirCount {
            for folder in byFolder.keys where folder.isWithin(top) { collect(folder) }
        } else {
            top.forEachDescendant { folder in
                collect(folder)
                return true
            }
        }
        return (folders, keys)
    }

    /// Replaces a file's links, or forgets the file when `group` is nil.
    mutating func set(_ key: HardLinkKey, to group: HardLinkGroup?) {
        if let old = groups[key] { unindex(old.links, of: key) }
        groups[key] = group
        if let group { index(group.links, as: key) }
    }

    /// Adds links to a file, recording the file first if it's new.
    mutating func add(_ links: [HardLink], to key: HardLinkKey, size: UInt64, modified: Int64) {
        groups[key, default: HardLinkGroup(size: size, modified: modified, links: [])].links += links
        index(links, as: key)
    }

    private mutating func index(_ links: [HardLink], as key: HardLinkKey) {
        for link in links { byFolder[link.node, default: [:]][link.name] = key }
    }

    private mutating func unindex(_ links: [HardLink], of key: HardLinkKey) {
        for link in links where byFolder[link.node]?[link.name] == key {
            byFolder[link.node]?[link.name] = nil
            if byFolder[link.node]?.isEmpty == true { byFolder[link.node] = nil }
        }
    }
}
