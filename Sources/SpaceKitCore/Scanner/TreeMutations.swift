import Foundation

/// In-place updates that keep a finished `ScanTree` in step with the disk after SpaceKit (or something else)
/// changes it, without rescanning everything.
///
/// Invariants preserved by every mutation (checked by `inconsistencies()` and the tests):
/// - `directFileSize == Σ files.size + otherFilesSize`, `directFileCount == files.count + otherFilesCount`
/// - `size == directFileSize + Σ children.size`
/// - `fileCount == directFileCount + Σ children.fileCount`, `dirCount == Σ (children.dirCount + 1)`
/// - a multiply-linked file's bytes are counted once, under the link a scan would credit (see `HardLinkGroup`)
///
/// Mutations must happen on one thread at a time, after the scan finished, with no other thread reading the
/// tree meanwhile (`Workspace` arranges that for the app and the TUI). See `DirNode` for the full threading rules.
extension ScanTree {
    // MARK: Removal

    /// Updates the tree after `path` was removed from disk. Returns the bytes taken out of the tree (less than
    /// the removed size when a hard link elsewhere keeps the file).
    ///
    /// - Parameters:
    ///   - looseFilesOnly: plain files directly inside `path` were removed. The cleanup may have skipped some
    ///     of them, so the folder is re-read to see which are left.
    ///   - bytes: the removed size, if known. Needed for small files, which the tree only knows as a
    ///     per-folder total.
    @discardableResult
    public func applyRemoval(of path: String, looseFilesOnly: Bool = false, bytes hint: UInt64? = nil) -> UInt64 {
        let before = root.size
        remove(path, looseFilesOnly: looseFilesOnly, hint: hint)
        return before - min(before, root.size)
    }

    private func remove(_ path: String, looseFilesOnly: Bool, hint: UInt64?) {
        if looseFilesOnly {
            if let node = node(at: path) { dropRemovedLooseFiles(of: node, at: path) }
            return
        }
        if let node = node(at: path), let parent = node.parent {
            detach(node, from: parent)
            let linked = hardLinks.linkedFolders(under: node)
            settleHardLinks(updateHardLinks(linked.keys) { linked.folders.contains($0.node) ? .drop : .keep })
            return
        }
        guard let parent = node(at: PathUtil.parent(path)) else { return }
        let name = PathUtil.lastComponent(path)
        let key: HardLinkKey? = hardLinks.links(in: parent)[name]
        guard takeFile(named: name, from: parent, hint: linkBytes(key, in: parent, named: name) ?? hint) != nil else { return }
        guard let key else { return }
        settleHardLinks(updateHardLinks([key]) { $0.node === parent && $0.name == name ? .drop : .keep })
    }

    // MARK: Move

    /// Updates the tree after `path` was moved to `destination` (for example into the Trash). If the
    /// destination's folder is part of the tree, the item reappears there under its new name, so totals
    /// stay correct: moving to the Trash doesn't free space until the Trash is emptied.
    /// Returns `true` if the item was re-attached at the destination.
    @discardableResult
    public func applyMove(of path: String, to destination: String, bytes hint: UInt64? = nil) -> Bool {
        let newName = PathUtil.lastComponent(destination)
        guard let target = node(at: PathUtil.parent(destination)), !PathUtil.isAncestorOrEqual(path, of: target.path) else {
            applyRemoval(of: path, bytes: hint)
            return false
        }
        if let node = node(at: path), let parent = node.parent {
            detach(node, from: parent)
            node.name = newName
            attach(node, to: target)
            // The links keep their folders, which may now sort ahead of (or behind) the link holding the bytes.
            settleHardLinks(hardLinks.linkedFolders(under: node).keys)
            return true
        }
        let name = PathUtil.lastComponent(path)
        guard let parent = node(at: PathUtil.parent(path)) else { return false }
        let key: HardLinkKey? = hardLinks.links(in: parent)[name]
        guard let leaf = takeFile(named: name, from: parent, hint: linkBytes(key, in: parent, named: name) ?? hint) else { return false }
        putFile(FileLeaf(name: newName, size: leaf.size, modified: leaf.modified), into: target)
        guard let key else { return true }
        settleHardLinks(updateHardLinks([key]) { $0.node === parent && $0.name == name ? .move(target, newName) : .keep })
        return true
    }

    // MARK: Arrival

    /// Updates the tree after a file appeared at `path` (a loose file moved to the Trash, say), reading its size
    /// from disk. Returns `true` if it was added, which needs its folder to be in the tree.
    @discardableResult
    func applyArrival(of path: String) -> Bool {
        guard let parent = node(at: PathUtil.parent(path)) else { return false }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { return false }
        let name = PathUtil.lastComponent(path)
        let size = FileSize.allocated(st)
        let modified = Int64(st.st_mtimespec.tv_sec)
        guard st.st_nlink > 1, (st.st_mode & S_IFMT) == S_IFREG else {
            putFile(FileLeaf(name: name, size: size, modified: modified), into: parent)
            return true
        }
        // Another link in the tree may already hold the bytes, so this one arrives empty and the order decides.
        let key = HardLinkKey(device: st.st_dev, inode: st.st_ino)
        hardLinks.add([HardLink(node: parent, name: name, hasBytes: false)], to: key, size: size, modified: modified)
        putFile(FileLeaf(name: name, size: 0, modified: modified), into: parent)
        settleHardLinks([key])
        return true
    }

    // MARK: Refresh

    /// Replaces the folder at `path` with a fresh scan of it (`fresh` must be a single-root scan of `path`).
    /// If the folder is new, it's added under its parent. Use it to resync one folder (say, the Trash after
    /// it was emptied in Finder) without rescanning the disk.
    public func splice(_ fresh: ScanTree, at path: String) {
        let path = PathUtil.standardize(path)
        let source = fresh.root
        guard !fresh.isMultiRoot, source.name == path || fresh.roots.first == path else { return }
        if let target = node(at: path) {
            // Drop the old contents' links before the nodes holding them can be freed.
            let old = hardLinks.linkedFolders(under: target)
            var touched = updateHardLinks(old.keys) { old.folders.contains($0.node) ? .drop : .keep }
            let delta = (
                bytes: Int64(source.size) - Int64(target.size),
                files: Int64(source.fileCount) - Int64(target.fileCount),
                dirs: Int64(source.dirCount) - Int64(target.dirCount)
            )
            target.children = source.children
            for child in target.children { child.setParent(target) }
            target.files = source.files
            target.otherFilesSize = source.otherFilesSize
            target.otherFilesCount = source.otherFilesCount
            target.directFileSize = source.directFileSize
            target.directFileCount = source.directFileCount
            target.markers = source.markers
            target.newestModified = source.newestModified
            target.newestAccessed = source.newestAccessed
            target.flags = source.flags
            target.size = source.size
            target.fileCount = source.fileCount
            target.dirCount = source.dirCount
            target.subtreeMarkers = source.subtreeMarkers
            target.subtreeNewestModified = source.subtreeNewestModified
            target.subtreeNewestAccessed = source.subtreeNewestAccessed
            renumberDepths(target)
            if let parent = target.parent {
                adjust(from: parent, bytes: delta.bytes, files: delta.files, dirs: delta.dirs)
                parent.children.sort { $0.size > $1.size }
            }
            touched.formUnion(adoptHardLinks(of: fresh, filesOf: source, nowIn: target))
            settleHardLinks(touched)
        } else if let parent = node(at: PathUtil.parent(path)) {
            source.name = PathUtil.lastComponent(path)
            attach(source, to: parent)
            settleHardLinks(adoptHardLinks(of: fresh, filesOf: source, nowIn: source))
        }
    }

    /// Updates the tree after part of the folder at `path` was removed: rescans it with the tree's own options and
    /// splices the result in, or drops it if it's gone. Returns `true` if the tree changed, which needs the folder
    /// to be in the tree.
    @discardableResult
    public func rescan(_ path: String) -> Bool {
        guard node(at: path) != nil else { return false }
        var st = stat()
        guard lstat(path, &st) == 0 else {
            applyRemoval(of: path)
            return true
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, let fresh = try? Scanner(options: options).scan(path) else { return false }
        splice(fresh, at: path)
        return true
    }

    // MARK: Verification

    /// Folders whose stored totals don't match their contents. Always empty unless there's a bug.
    public func inconsistencies(limit: Int = 20) -> [String] {
        var problems: [String] = []
        root.forEachDescendant { node in
            guard problems.count < limit else { return false }
            let leafBytes = node.files.reduce(UInt64(0)) { $0 + $1.size } + node.otherFilesSize
            let size = node.directFileSize + node.children.reduce(UInt64(0)) { $0 + $1.size }
            let files = UInt64(node.directFileCount) + node.children.reduce(UInt64(0)) { $0 + $1.fileCount }
            let dirs = node.children.reduce(UInt64(0)) { $0 + $1.dirCount + 1 }
            if node.name.isEmpty {
                if node.size != size { problems.append("(roots): size \(node.size) ≠ \(size)") }
                return true
            }
            if leafBytes != node.directFileSize { problems.append("\(node.path): files \(leafBytes) ≠ direct \(node.directFileSize)") }
            if node.size != size { problems.append("\(node.path): size \(node.size) ≠ \(size)") }
            if node.fileCount != files { problems.append("\(node.path): fileCount \(node.fileCount) ≠ \(files)") }
            if node.dirCount != dirs { problems.append("\(node.path): dirCount \(node.dirCount) ≠ \(dirs)") }
            for child in node.children where child.parent !== node { problems.append("\(child.path): wrong parent") }
            return true
        }
        return problems
    }

    // MARK: Helpers

    private func detach(_ node: DirNode, from parent: DirNode) {
        parent.children.removeAll { $0 === node }
        adjust(from: parent, bytes: -Int64(node.size), files: -Int64(node.fileCount), dirs: -Int64(node.dirCount + 1))
    }

    private func attach(_ node: DirNode, to parent: DirNode) {
        node.setParent(parent)
        renumberDepths(node)
        let index = parent.children.firstIndex { $0.size < node.size } ?? parent.children.count
        parent.children.insert(node, at: index)
        adjust(from: parent, bytes: Int64(node.size), files: Int64(node.fileCount), dirs: Int64(node.dirCount + 1))
        var cursor: DirNode? = parent
        while let ancestor = cursor {
            ancestor.subtreeMarkers |= node.subtreeMarkers
            ancestor.subtreeNewestModified = max(ancestor.subtreeNewestModified, node.subtreeNewestModified)
            cursor = ancestor.parent
        }
    }

    /// Keeps only the direct files of `node` that are still on disk. Never grows the folder: files that
    /// appeared since the scan aren't counted, and small files are capped at the folder's known total.
    private func dropRemovedLooseFiles(of node: DirNode, at path: String) {
        // An unreadable folder is treated as emptied, matching what the cleanup reported.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        var remaining: [String: UInt64] = [:]
        for name in names {
            var st = stat()
            guard lstat(PathUtil.join(path, name), &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { continue }
            remaining[name] = FileSize.allocated(st)
        }
        // A hard link weighs what the tree counts under it, which is 0 unless it holds the file's bytes.
        let links = hardLinks.links(in: node)
        for (name, key) in links where remaining[name] != nil { remaining[name] = linkBytes(key, in: node, named: name) }
        let files = node.files.filter { remaining[$0.name] != nil }
        let tracked = Set(node.files.map(\.name))
        let small = remaining.filter { !tracked.contains($0.key) }
        let otherSize = min(node.otherFilesSize, small.values.reduce(0, &+))
        let otherCount = min(node.otherFilesCount, UInt32(small.count))
        let directSize = files.reduce(0) { $0 &+ $1.size } &+ otherSize
        let directCount = UInt32(files.count) + otherCount

        let bytes = node.directFileSize - min(node.directFileSize, directSize)
        let count = node.directFileCount - min(node.directFileCount, directCount)
        node.files = files
        node.otherFilesSize = otherSize
        node.otherFilesCount = otherCount
        node.directFileSize = directSize
        node.directFileCount = directCount
        adjust(from: node, bytes: -Int64(bytes), files: -Int64(count), dirs: 0)
        let gone = Set(links.filter { remaining[$0.key] == nil }.values)
        settleHardLinks(updateHardLinks(gone) { $0.node === node && remaining[$0.name] == nil ? .drop : .keep })
    }

    /// Removes a file from a folder's direct contents. Small files only exist as a total, so `hint` gives their size.
    private func takeFile(named name: String, from parent: DirNode, hint: UInt64?) -> FileLeaf? {
        let leaf: FileLeaf
        if let index = parent.files.firstIndex(where: { $0.name == name }) {
            leaf = parent.files.remove(at: index)
        } else if let hint, parent.otherFilesCount > 0 {
            let size = min(hint, parent.otherFilesSize)
            parent.otherFilesSize -= size
            parent.otherFilesCount -= 1
            leaf = FileLeaf(name: name, size: size, modified: 0)
        } else {
            return nil
        }
        parent.directFileSize -= min(parent.directFileSize, leaf.size)
        parent.directFileCount -= min(parent.directFileCount, 1)
        adjust(from: parent, bytes: -Int64(leaf.size), files: -1, dirs: 0)
        return leaf
    }

    private func putFile(_ leaf: FileLeaf, into parent: DirNode) {
        if leaf.size >= options.minFileSize && leaf.size > 0 {
            let index = parent.files.firstIndex { $0.size < leaf.size } ?? parent.files.count
            parent.files.insert(leaf, at: index)
        } else {
            parent.otherFilesSize += leaf.size
            parent.otherFilesCount += 1
        }
        parent.directFileSize += leaf.size
        parent.directFileCount += 1
        adjust(from: parent, bytes: Int64(leaf.size), files: 1, dirs: 0)
    }

    // MARK: Hard links

    /// What the tree counts under the hard link `name` in `folder`, which names file `key`: the file's size if
    /// the link holds it, 0 otherwise. `nil` if it isn't a hard link.
    private func linkBytes(_ key: HardLinkKey?, in folder: DirNode, named name: String) -> UInt64? {
        guard let key, let group = hardLinks[key] else { return nil }
        guard let link = group.links.first(where: { $0.node === folder && $0.name == name }) else { return nil }
        return link.hasBytes ? group.size : 0
    }

    /// Applies `change` to the links of each file in `keys` and returns the files that still exist.
    private func updateHardLinks(_ keys: Set<HardLinkKey>, _ change: (HardLink) -> HardLinkChange) -> Set<HardLinkKey> {
        var updated: Set<HardLinkKey> = []
        for key in keys {
            guard let group = hardLinks[key] else { continue }
            var links: [HardLink] = []
            for link in group.links {
                switch change(link) {
                case .keep: links.append(link)
                case .drop: break
                case .move(let node, let name): links.append(HardLink(node: node, name: name, hasBytes: link.hasBytes))
                }
            }
            hardLinks.set(key, to: HardLinkGroup(size: group.size, modified: group.modified, links: links))
            updated.insert(key)
        }
        return updated
    }

    /// Takes in the hard links of `fresh`, a scan spliced into this tree whose root's files now live in `target`.
    private func adoptHardLinks(of fresh: ScanTree, filesOf source: DirNode, nowIn target: DirNode) -> Set<HardLinkKey> {
        for (key, group) in fresh.hardLinks.groups {
            let links: [HardLink] = group.links.map { link in
                link.node === source ? HardLink(node: target, name: link.name, hasBytes: link.hasBytes) : link
            }
            hardLinks.add(links, to: key, size: group.size, modified: group.modified)
        }
        return Set(fresh.hardLinks.groups.keys)
    }

    /// Moves each group's bytes to the link a rescan would credit, and forgets groups with no link left.
    private func settleHardLinks(_ keys: Set<HardLinkKey>) {
        let minFileSize = options.minFileSize
        for key in keys {
            guard var group = hardLinks[key] else { continue }
            guard let owner = group.ownerIndex else {
                hardLinks.set(key, to: nil)
                continue
            }
            let size = group.size
            for index in group.links.indices where index != owner && group.links[index].hasBytes {
                let link = group.links[index]
                guard link.node.dropLinkBytes(named: link.name, size: size, minFileSize: minFileSize) else { continue }
                adjust(from: link.node, bytes: -Int64(size), files: 0, dirs: 0)
                group.links[index].hasBytes = false
            }
            // A link that couldn't give its bytes up still holds them; counting them twice would be worse.
            if !group.links.contains(where: { $0.hasBytes }) {
                let link = group.links[owner]
                link.node.addLinkBytes(named: link.name, size: size, modified: group.modified, minFileSize: minFileSize)
                adjust(from: link.node, bytes: Int64(size), files: 0, dirs: 0)
                group.links[owner].hasBytes = true
            }
            hardLinks.set(key, to: group)
        }
    }

    /// Adds signed deltas to `start` and every ancestor.
    private func adjust(from start: DirNode, bytes: Int64, files: Int64, dirs: Int64) {
        func apply(_ value: inout UInt64, _ delta: Int64) {
            value = delta >= 0 ? value &+ UInt64(delta) : value - min(value, UInt64(-delta))
        }
        var cursor: DirNode? = start
        while let node = cursor {
            apply(&node.size, bytes)
            apply(&node.fileCount, files)
            apply(&node.dirCount, dirs)
            cursor = node.parent
        }
    }

    private func renumberDepths(_ start: DirNode) {
        start.depth = (start.parent?.depth ?? -1) + 1
        var stack = start.children
        while let node = stack.popLast() {
            node.depth = (node.parent?.depth ?? -1) + 1
            stack.append(contentsOf: node.children)
        }
    }
}

/// What a tree mutation did to one hard link.
private enum HardLinkChange {
    case keep
    /// Gone from the tree, along with any bytes it held.
    case drop
    /// Renamed or moved to another folder, along with any bytes it held.
    case move(DirNode, String)
}
