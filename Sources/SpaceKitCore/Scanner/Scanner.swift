import Darwin
import Foundation
import Synchronization

/// A fast, parallel disk scanner.
///
/// Performance notes:
/// - Directories are read with `getattrlistbulk(2)`, which returns names, types, sizes and dates for
///   many entries in one system call. That's several times faster than `FileManager` enumeration and
///   avoids a `stat` per file.
/// - A pool of worker threads pulls directories from a shared LIFO stack. Each worker keeps one child
///   for itself and shares the rest, so the stack stays small and threads rarely contend.
/// - Swift `String`s are only created for directories and for files large enough to be tracked.
///   Marker files (`package.json`, `.git`, …) are recognised by comparing raw bytes.
/// - Sizes are allocated bytes (what the disk actually spends), and hard-linked files are counted once.
public struct Scanner: Sendable {
    public var options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    /// Scans one directory tree. Blocks the calling thread; see the `async` overload for UI use.
    public func scan(_ path: String, progress: ScanProgress = ScanProgress()) throws -> ScanTree {
        try scan(roots: [path], progress: progress)
    }

    /// Scans several directory trees into one tree. With more than one root, `ScanTree.root` is a virtual
    /// node with an empty name whose children are the roots (named by absolute path).
    public func scan(roots paths: [String], progress: ScanProgress = ScanProgress()) throws -> ScanTree {
        let started = Date()
        let clock = ContinuousClock.now
        var resolved: [String] = []
        for path in paths {
            // Exactly as given: `report ` and `report` are different folders.
            let expanded = PathUtil.expandArgument(path)
            guard let real = PathUtil.realpath(expanded) else { throw ScanError.notFound(expanded) }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ScanError.notADirectory(real)
            }
            resolved.append(real)
        }
        // Drop roots nested inside other roots so nothing is counted twice.
        resolved = Array(Set(resolved)).sorted().filter { candidate in
            !resolved.contains { $0 != candidate && PathUtil.isStrictAncestor($0, of: candidate) }
        }
        guard !resolved.isEmpty else { throw ScanError.notFound(paths.first ?? "") }

        let volumes = VolumeTable.current()
        let job = ScanJob(options: options, progress: progress, volumes: volumes, roots: resolved)

        let root: DirNode
        if resolved.count == 1 {
            root = DirNode(name: resolved[0], parent: nil)
            job.seed([job.makeRootItem(node: root, path: resolved[0])])
        } else {
            root = DirNode(name: "", parent: nil)
            let rootNodes = resolved.map { DirNode(name: $0, parent: root) }
            root.children = rootNodes
            root.listed.store(true, ordering: .releasing)
            progress.rootChildren.withLock { $0 = rootNodes }
            job.seed(zip(rootNodes, resolved).map { job.makeRootItem(node: $0.0, path: $0.1) })
        }
        progress.root.withLock { $0 = root }

        job.run()
        let hardLinks = job.resolveHardLinks()
        Scanner.aggregate(root)

        let snapshot = progress.snapshot
        let stats = ScanStats(
            files: snapshot.files,
            directories: snapshot.directories,
            errors: snapshot.errors,
            duration: (ContinuousClock.now - clock) / .seconds(1),
            cancelled: progress.isCancelled
        )
        return ScanTree(
            root: root, roots: resolved, stats: stats, options: options,
            capacity: VolumeCapacity.of(path: resolved[0]), scanStarted: started, hardLinks: hardLinks
        )
    }

    /// Runs the scan on dedicated threads without blocking Swift's cooperative pool. Cancelling the task
    /// stops the scan and returns the partial tree.
    public func scan(roots: [String], progress: ScanProgress = ScanProgress()) async throws -> ScanTree {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread {
                    do {
                        continuation.resume(returning: try self.scan(roots: roots, progress: progress))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.name = "SpaceKit.scan"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            progress.cancel()
        }
    }

    public func scan(_ path: String, progress: ScanProgress = ScanProgress()) async throws -> ScanTree {
        try await scan(roots: [path], progress: progress)
    }

    /// Bottom-up totals without recursion, then sorts children largest-first.
    static func aggregate(_ root: DirNode) {
        var order: [DirNode] = []
        var stack: [DirNode] = [root]
        while let node = stack.popLast() {
            order.append(node)
            stack.append(contentsOf: node.children)
        }
        for node in order.reversed() {
            var size = node.directFileSize
            var files = UInt64(node.directFileCount)
            var dirs: UInt64 = 0
            var markers = node.markers
            var newestModified = node.newestModified
            var newestAccessed = node.newestAccessed
            for child in node.children {
                size &+= child.size
                files &+= child.fileCount
                dirs &+= child.dirCount + 1
                markers |= child.subtreeMarkers
                newestModified = max(newestModified, child.subtreeNewestModified)
                newestAccessed = max(newestAccessed, child.subtreeNewestAccessed)
            }
            node.size = size
            node.fileCount = files
            node.dirCount = dirs
            node.subtreeMarkers = markers
            node.subtreeNewestModified = newestModified
            node.subtreeNewestAccessed = newestAccessed
            if node.children.count > 1 { node.children.sort { $0.size > $1.size } }
            if node.files.count > 1 { node.files.sort { $0.size > $1.size } }
        }
    }
}

// MARK: - Work pool

private struct WorkItem {
    let node: DirNode
    let path: String
    /// Ancestors (and possibly the node itself) that keep a live byte count.
    let anchors: [DirNode]
}

/// One multiply-linked file. During the scan its bytes go to the first link a worker reaches, so live totals
/// stay right; afterwards they move to the link `HardLinkGroup.precedes` puts first, so the same disk always
/// gives the same tree whatever the thread timing.
private struct HardLinkEntry {
    let size: UInt64
    let modified: Int64
    let credited: DirNode
    let creditedName: String
    var links: [HardLink]
}

private final class ScanJob: @unchecked Sendable {
    let options: ScanOptions
    let progress: ScanProgress
    let allowedDevices: Set<dev_t>?
    /// Mount point path → device, used to decide whether to cross into a mount without opening it.
    let mountDevices: [String: dev_t]
    let virtualFileSystems: Set<String>
    /// Exact paths to skip, with the reason flag.
    let skipPaths: [String: DirNode.Flags]
    let excludeGlobs: [String]
    let hardLinks = Mutex<[HardLinkKey: HardLinkEntry]>([:])

    private let condition = NSCondition()
    private var stack: [WorkItem] = []
    private var pending = 0
    private var finished = false

    init(options: ScanOptions, progress: ScanProgress, volumes: VolumeTable, roots: [String]) {
        self.options = options
        self.progress = progress

        let rootDevices = Set(
            roots.compactMap { root -> dev_t? in
                var st = stat()
                return lstat(root, &st) == 0 ? st.st_dev : nil
            })
        switch options.boundary {
        case .device: allowedDevices = rootDevices
        case .container: allowedDevices = rootDevices.union(roots.flatMap { volumes.containerDevices(for: $0) })
        case .unrestricted: allowedDevices = nil
        }

        var mounts: [String: dev_t] = [:]
        var virtual = Set<String>()
        for volume in volumes.volumes {
            mounts[volume.mountPoint] = volume.deviceID
            if ["devfs", "autofs", "nullfs", "fdesc"].contains(volume.fileSystem) { virtual.insert(volume.mountPoint) }
        }
        mountDevices = mounts
        virtualFileSystems = virtual

        var skip: [String: DirNode.Flags] = [:]
        for root in roots {
            for path in volumes.duplicateFirmlinkTargets(whenScanning: root) { skip[path] = .firmlinkDuplicate }
        }
        var globs: [String] = []
        for pattern in options.exclude {
            let expanded = PathUtil.expand(pattern)
            if expanded.contains(where: { "*?[".contains($0) }) {
                globs.append(expanded)
            } else {
                skip[expanded] = .excluded
            }
        }
        skipPaths = skip
        excludeGlobs = globs
    }

    func makeRootItem(node: DirNode, path: String) -> WorkItem {
        WorkItem(node: node, path: path, anchors: node.depth <= options.liveDepth ? [node] : [])
    }

    func seed(_ items: [WorkItem]) {
        stack = items
        pending = items.count
        finished = items.isEmpty
    }

    func run() {
        let threadCount = max(1, options.threads)
        let group = DispatchGroup()
        for index in 0..<threadCount {
            group.enter()
            let thread = Thread { [self] in
                self.workerLoop()
                group.leave()
            }
            thread.name = "SpaceKit.scan.\(index)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()
    }

    private func pop() -> WorkItem? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty && !finished { condition.wait() }
        return finished && stack.isEmpty ? nil : stack.removeLast()
    }

    /// Shares `items` with other workers. `reserved` counts additional items the caller keeps for itself.
    private func share(_ items: ArraySlice<WorkItem>, reserved: Int) {
        condition.lock()
        stack.append(contentsOf: items)
        pending += items.count + reserved
        if items.count > 1 { condition.broadcast() } else if items.count == 1 { condition.signal() }
        condition.unlock()
    }

    private func complete() {
        condition.lock()
        pending -= 1
        if pending == 0 {
            finished = true
            condition.broadcast()
        }
        condition.unlock()
    }

    private func workerLoop() {
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var listed = 0
        while let first = pop() {
            var current: WorkItem? = first
            while let item = current {
                let subdirectories = list(item, buffer: buffer, bufferSize: bufferSize)
                if let keep = subdirectories.last {
                    share(subdirectories.dropLast(), reserved: 1)
                    current = keep
                } else {
                    current = nil
                }
                listed += 1
                if listed & 63 == 0 { progress.currentPath.withLock { $0 = item.path } }
                complete()
            }
        }
    }

    // MARK: Hard links

    /// Records one link of a multiply-linked file. Returns true if this is the first link seen, which gets
    /// the bytes for now.
    private func recordHardLink(_ key: HardLinkKey, node: DirNode, name: String, size: UInt64, modified: Int64) -> Bool {
        let link = HardLink(node: node, name: name, hasBytes: false)
        return hardLinks.withLock { table in
            guard let index = table.index(forKey: key) else {
                table[key] = HardLinkEntry(size: size, modified: modified, credited: node, creditedName: name, links: [link])
                return true
            }
            table.values[index].links.append(link)
            return false
        }
    }

    /// Moves each multiply-linked file's bytes from the link credited during the scan to its owner, and returns
    /// the links for the tree to keep. Runs once, single-threaded, after every worker has finished and before
    /// aggregation.
    func resolveHardLinks() -> [HardLinkKey: HardLinkGroup] {
        let table = hardLinks.withLock { table in
            defer { table = [:] }
            return table
        }
        let minFileSize = options.minFileSize
        var groups: [HardLinkKey: HardLinkGroup] = [:]
        groups.reserveCapacity(table.count)
        // Many links share a folder; building its path once per folder keeps this pass cheap.
        var folderPaths: [DirNode: String] = [:]
        func path(of folder: DirNode) -> String {
            if let known = folderPaths[folder] { return known }
            let path = folder.path
            folderPaths[folder] = path
            return path
        }
        for (key, entry) in table {
            var group = HardLinkGroup(size: entry.size, modified: entry.modified, links: entry.links)
            guard let ownerIndex = group.ownerIndex(path: path(of:)) else { continue }
            let owner: HardLink = group.links[ownerIndex]
            var holder: DirNode = entry.credited
            var holderName: String = entry.creditedName
            let moves = owner.node !== holder || owner.name != holderName
            // The links themselves stay counted where they are; only the bytes (and the tracked leaf) move.
            if moves && holder.dropLinkBytes(named: holderName, size: entry.size, minFileSize: minFileSize) {
                owner.node.addLinkBytes(named: owner.name, size: entry.size, modified: entry.modified, minFileSize: minFileSize)
                holder = owner.node
                holderName = owner.name
            }
            for index in group.links.indices {
                group.links[index].hasBytes = group.links[index].node === holder && group.links[index].name == holderName
            }
            groups[key] = group
        }
        return groups
    }

    // MARK: Listing one directory

    private func publish(_ node: DirNode) {
        node.listed.store(true, ordering: .releasing)
    }

    private func markUnreadable(_ item: WorkItem) {
        item.node.flags.insert(.unreadable)
        progress.errors.add(1, ordering: .relaxed)
    }

    private func skipFlag(for path: String) -> DirNode.Flags? {
        if let flag = skipPaths[path] { return flag }
        if virtualFileSystems.contains(path) { return .otherVolume }
        if let device = mountDevices[path], let allowed = allowedDevices, !allowed.contains(device) { return .otherVolume }
        for glob in excludeGlobs where PathUtil.matches(path, glob: glob) { return .excluded }
        return nil
    }

    /// Lists one directory, records its files and returns work items for its subdirectories.
    private func list(_ item: WorkItem, buffer: UnsafeMutableRawPointer, bufferSize: Int) -> [WorkItem] {
        let node = item.node
        if progress.isCancelled {
            publish(node)
            return []
        }

        let fd = open(item.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            markUnreadable(item)
            publish(node)
            return []
        }
        defer { close(fd) }

        if let allowed = allowedDevices {
            var st = stat()
            if fstat(fd, &st) == 0, !allowed.contains(st.st_dev) {
                node.flags.insert(.otherVolume)
                publish(node)
                return []
            }
        }

        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(
                ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE
                    | ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME | ATTR_CMN_FILEID)
        attributes.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        attributes.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)

        let minFileSize = options.minFileSize
        let liveDepth = options.liveDepth

        var childNodes: [DirNode] = []
        var childItems: [WorkItem] = []
        var files: [FileLeaf] = []
        var directBytes: UInt64 = 0
        var directCount: UInt32 = 0
        var otherBytes: UInt64 = 0
        var otherCount: UInt32 = 0
        var markers: UInt64 = 0
        var newestModified: Int64 = 0
        var newestAccessed: Int64 = 0
        var entryErrors: UInt64 = 0

        let childAnchors = item.anchors

        readLoop: while true {
            let count = getattrlistbulk(fd, &attributes, buffer, bufferSize, 0)
            if count < 0 {
                if errno == EINTR { continue }
                markUnreadable(item)
                break readLoop
            }
            if count == 0 { break }

            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + MemoryLayout<UInt32>.size
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                // ATTR_CMN_ERROR is packed right after the returned-attributes set.
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    let error = field.loadUnaligned(as: UInt32.self)
                    field += 4
                    if error != 0 {
                        entryErrors += 1
                        continue
                    }
                }

                var namePointer: UnsafePointer<UInt8>?
                var nameLength = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let reference = field.loadUnaligned(as: attrreference_t.self)
                    namePointer = (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
                    nameLength = max(0, Int(reference.attr_length) - 1)  // length includes the NUL
                    field += MemoryLayout<attrreference_t>.size
                }
                var device: Int32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
                    device = field.loadUnaligned(as: Int32.self)
                    field += 4
                }
                var objectType: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    objectType = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var modified: Int64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    modified = Int64(field.loadUnaligned(as: timespec.self).tv_sec)
                    field += MemoryLayout<timespec>.size
                }
                var accessed: Int64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_ACCTIME) != 0 {
                    accessed = Int64(field.loadUnaligned(as: timespec.self).tv_sec)
                    field += MemoryLayout<timespec>.size
                }
                var inode: UInt64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    inode = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }

                guard let name = namePointer, nameLength > 0 else { continue }
                markers |= options.markers.lookup(name, length: nameLength)

                if objectType == UInt32(VDIR.rawValue) {
                    var mountStatus: UInt32 = 0
                    if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
                        mountStatus = field.loadUnaligned(as: UInt32.self)
                        field += 4
                    }
                    newestModified = max(newestModified, modified)
                    let childName = String(decoding: UnsafeBufferPointer(start: name, count: nameLength), as: UTF8.self)
                    let childPath = item.path == "/" ? "/" + childName : item.path + "/" + childName
                    let child = DirNode(name: childName, parent: node)
                    childNodes.append(child)

                    if mountStatus & UInt32(DIR_MNTSTATUS_TRIGGER) != 0 {
                        // autofs trigger: opening it would try to mount a network share.
                        child.flags.insert(.otherVolume)
                        publish(child)
                        continue
                    }
                    if let flag = skipFlag(for: childPath) {
                        child.flags.insert(flag)
                        publish(child)
                        continue
                    }
                    let anchors = child.depth <= liveDepth ? childAnchors + [child] : childAnchors
                    childItems.append(WorkItem(node: child, path: childPath, anchors: anchors))
                } else {
                    var linkCount: UInt32 = 1
                    if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                        linkCount = field.loadUnaligned(as: UInt32.self)
                        field += 4
                    }
                    var allocated: UInt64 = 0
                    if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                        allocated = UInt64(max(0, field.loadUnaligned(as: Int64.self)))
                        field += 8
                    }
                    if linkCount > 1, objectType == UInt32(VREG.rawValue) {
                        let fileName = String(decoding: UnsafeBufferPointer(start: name, count: nameLength), as: UTF8.self)
                        let isFirst = recordHardLink(
                            HardLinkKey(device: device, inode: inode), node: node, name: fileName,
                            size: allocated, modified: modified)
                        if !isFirst { allocated = 0 }
                    }
                    directBytes &+= allocated
                    directCount &+= 1
                    newestModified = max(newestModified, modified)
                    newestAccessed = max(newestAccessed, accessed)
                    if allocated >= minFileSize && allocated > 0 {
                        let fileName = String(decoding: UnsafeBufferPointer(start: name, count: nameLength), as: UTF8.self)
                        files.append(FileLeaf(name: fileName, size: allocated, modified: modified))
                    } else {
                        otherBytes &+= allocated
                        otherCount &+= 1
                    }
                }
            }
        }

        node.children = childNodes
        node.files = files
        node.directFileSize = directBytes
        node.directFileCount = directCount
        node.otherFilesSize = otherBytes
        node.otherFilesCount = otherCount
        node.markers = markers
        node.newestModified = newestModified
        node.newestAccessed = newestAccessed
        publish(node)
        if node.parent == nil { progress.rootChildren.withLock { $0 = childNodes } }

        for anchor in item.anchors { anchor.liveBytes.add(directBytes, ordering: .relaxed) }
        progress.files.add(UInt64(directCount), ordering: .relaxed)
        progress.directories.add(1, ordering: .relaxed)
        progress.bytes.add(directBytes, ordering: .relaxed)
        if entryErrors > 0 { progress.errors.add(entryErrors, ordering: .relaxed) }

        return childItems
    }
}
