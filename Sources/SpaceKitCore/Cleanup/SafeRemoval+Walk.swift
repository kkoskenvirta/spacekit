import Foundation

/// The walk behind `SafeRemoval.delete`: it empties a folder tree without recursion and with one folder open at a
/// time. For the folders above the current one it keeps only their identity (device and inode), and it climbs back
/// through `..`, checking that it arrives in the folder it came from. If a folder was moved elsewhere meanwhile, the
/// walk stops instead of carrying on in the new parent. Entries that can't be removed are left and counted, and the
/// walk carries on with the rest. A folder on another device than the item is a volume mounted inside it: the walk
/// never enters it, and leaves it with the folders above it.
struct TreeWalk {
    /// A folder the walk is inside, from the item down to the current one.
    struct Frame {
        var device: dev_t
        var inode: ino_t
        /// Its name in the folder above.
        var name: [CChar]
        /// Entries not visited yet.
        var pending: [[CChar]]
        /// Entries that couldn't be removed, so a fresh listing doesn't retry them.
        var kept: Set<[CChar]> = []
        /// Something in here couldn't be removed and is already counted, so the folder itself isn't counted again.
        var failed = false
        /// A volume is mounted somewhere below, so the folder stays without that being a failure.
        var holdsVolume = false
        var passes = 1
    }

    /// The item's path, for messages.
    let root: String
    /// The item's device. A folder on another one is a mounted volume.
    let volume: dev_t
    let device: SafeRemoval.DeviceReader
    private(set) var firstFailure: (path: String, code: Int32)?
    private(set) var failureCount = 0
    /// Folders left because another volume is mounted on them.
    private(set) var leftOnOtherVolumes: [String] = []
    private var stack: [Frame] = []

    init(root: String, volume: dev_t, device: @escaping SafeRemoval.DeviceReader) {
        self.root = root
        self.volume = volume
        self.device = device
    }

    /// Empties the folder `name` (open as `top`) and removes it from `parent`. Closes `top`.
    mutating func remove(_ name: [CChar], opened top: Int32, in parent: Int32) throws {
        var current = top
        defer { close(current) }
        let item = frame(for: current, name: name)
        stack = [item]
        while let index = stack.indices.last {
            if let entry = stack[index].pending.popLast() {
                guard let opened = visit(entry, in: current), let child = onItemVolume(opened, named: entry) else { continue }
                close(current)
                current = child
                stack.append(frame(for: child, name: entry))
                continue
            }
            if relist(current) { continue }
            let finished = stack.removeLast()
            guard let above = stack.last else {
                removeFolder(finished, in: parent, isItem: true)
                return
            }
            current = try ascend(from: current, leaving: finished, to: above)
            removeFolder(finished, in: current)
        }
    }

    /// Removes `entry` of the folder open as `folder` if it's anything but a folder. Returns a handle to it when
    /// it's a folder to walk into, `nil` otherwise.
    private mutating func visit(_ entry: [CChar], in folder: Int32) -> Int32? {
        if unlinkat(folder, entry, 0) == 0 || errno == ENOENT { return nil }
        // macOS answers EPERM for unlink on a folder; an immutable file gives the same answer.
        guard errno == EPERM || errno == EISDIR else {
            keep(entry, code: errno)
            return nil
        }
        let child = openat(folder, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if child >= 0 { return child }
        // Not a folder (any more): try the entry itself once more; what still fails stays.
        if errno == ENOTDIR || errno == ELOOP, unlinkat(folder, entry, 0) == 0 || errno == ENOENT { return nil }
        if errno != ENOENT { keep(entry, code: errno) }
        return nil
    }

    /// `child` (the subfolder `entry`, just opened) when it is on the item's volume, so the walk goes into it.
    /// Otherwise it is closed and `nil` returned: a folder on another device is a mounted volume, left as it is, and
    /// one whose device can't be read is left and counted.
    private mutating func onItemVolume(_ child: Int32, named entry: [CChar]) -> Int32? {
        let childDevice = device(child)
        if childDevice == volume { return child }
        let code = errno
        close(child)
        if childDevice == nil { keep(entry, code: code) } else { leaveMounted(entry) }
        return nil
    }

    /// Lists the current folder again once it's been worked through, to catch entries that appeared meanwhile.
    /// Returns true if there is more to do.
    private mutating func relist(_ folder: Int32) -> Bool {
        guard let index = stack.indices.last, stack[index].passes < SafeRemoval.emptyingPasses else { return false }
        guard let names = SafeRemoval.entryNames(of: folder) else { return false }
        let kept = stack[index].kept
        let fresh = names.filter { !kept.contains($0) }
        guard !fresh.isEmpty else { return false }
        stack[index].pending = fresh
        stack[index].passes += 1
        return true
    }

    /// Opens the folder above `folder` (the emptied `finished`) and checks it is `expected`, then closes `folder`.
    private func ascend(from folder: Int32, leaving finished: Frame, to expected: Frame) throws -> Int32 {
        let up = openat(folder, SafeRemoval.parentFolder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var st = stat()
        guard up >= 0, fstat(up, &st) == 0, st.st_dev == expected.device, st.st_ino == expected.inode else {
            if up >= 0 { close(up) }
            let moved = path(of: finished.name)
            throw SafeRemoval.Stopped(errorDescription: "\(moved) was moved while it was being removed; stopped there")
        }
        close(folder)
        return up
    }

    /// Removes an emptied folder from the folder open as `parent`. `isItem`: it is the item itself, not a folder inside it.
    private mutating func removeFolder(_ finished: Frame, in parent: Int32, isItem: Bool = false) {
        if unlinkat(parent, finished.name, AT_REMOVEDIR) == 0 || errno == ENOENT { return }
        let code = errno
        // Swapped for a link or a file after it was opened: what the handle reached is empty; drop the entry. Inside
        // the item that entry goes anyway; in the item's own place it is something else, outside the item, and stays.
        if code == ENOTDIR, !isItem, unlinkat(parent, finished.name, 0) == 0 || errno == ENOENT { return }
        if finished.holdsVolume { holdVolume(finished.name) }
        // Left only because a volume is mounted below it: that isn't a failure.
        if finished.holdsVolume && !finished.failed && code == ENOTEMPTY { return }
        keep(finished.name, code: code, counted: finished.failed)
    }

    /// Leaves `entry` of the current folder, a volume mounted inside the item, as it is.
    private mutating func leaveMounted(_ entry: [CChar]) {
        leftOnOtherVolumes.append(path(of: entry))
        holdVolume(entry)
    }

    /// Marks the current folder as holding a mounted volume at or below its entry `entry`, which stays.
    private mutating func holdVolume(_ entry: [CChar]) {
        guard let index = stack.indices.last else { return }
        stack[index].kept.insert(entry)
        stack[index].holdsVolume = true
    }

    private mutating func frame(for fd: Int32, name: [CChar]) -> Frame {
        var st = stat()
        fstat(fd, &st)
        var frame = Frame(device: st.st_dev, inode: st.st_ino, name: name, pending: [])
        if let names = SafeRemoval.entryNames(of: fd) {
            frame.pending = names
        } else {
            record(path(of: name), code: errno)
            frame.failed = true
        }
        return frame
    }

    /// Leaves `entry` of the current folder in place and counts it, unless what made it fail is counted already.
    private mutating func keep(_ entry: [CChar], code: Int32, counted: Bool = false) {
        if !counted { record(path(of: entry), code: code) }
        guard let index = stack.indices.last else { return }
        stack[index].kept.insert(entry)
        stack[index].failed = true
    }

    private mutating func record(_ path: String, code: Int32) {
        failureCount += 1
        if firstFailure == nil { firstFailure = (path, code) }
    }

    /// Path of `entry` of the current folder; the item itself when the walk isn't inside it.
    private func path(of entry: [CChar]) -> String {
        guard !stack.isEmpty else { return root }
        let folder = stack.dropFirst().reduce(root) { $0 + "/" + TreeWalk.text($1.name) }
        return folder + "/" + TreeWalk.text(entry)
    }

    private static func text(_ name: [CChar]) -> String {
        String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
