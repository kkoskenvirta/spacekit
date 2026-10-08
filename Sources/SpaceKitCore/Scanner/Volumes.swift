import Foundation

/// A mounted file system.
public struct MountedVolume: Sendable, Hashable, Identifiable {
    public var id: String { mountPoint }
    /// e.g. `/`, `/System/Volumes/Data`, `/Volumes/External`
    public let mountPoint: String
    /// e.g. `/dev/disk3s5`
    public let device: String
    public let fileSystem: String
    public let deviceID: dev_t
    public let isBrowsable: Bool

    /// The APFS container (or whole disk) this volume lives on, e.g. `disk3` for `/dev/disk3s5` or `/dev/disk3s1s1`.
    public var container: String? {
        guard device.hasPrefix("/dev/disk") else { return nil }
        let name = device.dropFirst("/dev/".count)
        // diskN followed by sM (and possibly sK for snapshots)
        var end = name.index(name.startIndex, offsetBy: 4)
        while end < name.endIndex, name[end].isNumber { end = name.index(after: end) }
        return String(name[..<end])
    }
}

/// Capacity of the volume that contains a path.
///
/// macOS reports two different "free" numbers, and confusing them makes a cleanup look like it did nothing:
///
/// - `freeNow`: blocks not allocated to anything right now.
/// - `available`: `freeNow` plus space macOS will reclaim on demand: purgeable caches, iCloud files it can
///   evict, and **local Time Machine snapshots**. This is what Finder calls "Available".
///
/// When you delete files while local snapshots exist, their blocks stay referenced by the snapshots, so
/// `freeNow` doesn't move but `available` (and `purgeable`) grow by what you deleted. The space is released
/// automatically when macOS needs it or when the snapshots expire (about 24 hours).
public struct VolumeCapacity: Sendable, Codable, Hashable {
    public var name: String
    public var mountPoint: String
    public var total: UInt64
    /// Unallocated bytes right now.
    public var freeNow: UInt64
    /// Bytes available for new data, including space macOS will purge on demand (Finder's "Available").
    public var available: UInt64

    /// Space macOS reclaims on demand: local snapshots, purgeable caches, evictable iCloud files.
    public var purgeable: UInt64 { available > freeNow ? available - freeNow : 0 }
    /// Space holding data you can't get back without deleting something (Finder's "Used").
    public var used: UInt64 { total &- min(total, available) }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

    public init(name: String, mountPoint: String, total: UInt64, freeNow: UInt64, available: UInt64) {
        self.name = name
        self.mountPoint = mountPoint
        self.total = total
        self.freeNow = min(freeNow, total)
        self.available = min(max(available, freeNow), total)
    }

    /// Reads capacity for the volume holding `path`. Values are read fresh on every call.
    public static func of(path: String) -> VolumeCapacity? {
        var url = URL(fileURLWithPath: path)
        // Resource values are cached per URL instance; make sure we never see a stale value.
        url.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeURLKey, .volumeLocalizedNameKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
            let total = values.volumeTotalCapacity
        else { return nil }
        let freeNow = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
        let important = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? Int64(freeNow)))
        return VolumeCapacity(
            name: values.volumeLocalizedName ?? values.volumeName ?? "Volume",
            mountPoint: values.volume?.path ?? "/",
            total: UInt64(max(0, total)),
            freeNow: freeNow,
            available: important
        )
    }
}

/// Local Time Machine snapshots, which keep deleted files' blocks allocated until they're thinned.
public enum LocalSnapshots {
    /// Snapshot names on the startup disk (empty if there are none or `tmutil` isn't available).
    public static func list() -> [String] {
        let result = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 10)
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map(String.init).filter { $0.contains("com.apple.") && !$0.hasPrefix("Snapshots") }
    }

    /// The command that releases snapshot-held space right away. It must be run by the person, in Terminal;
    /// SpaceKit never thins backups itself.
    public static func thinCommand() -> String {
        "tmutil thinlocalsnapshots / 999999999999 4"
    }
}

/// The table of mounted file systems plus macOS firmlink knowledge.
public struct VolumeTable: Sendable {
    public let volumes: [MountedVolume]

    /// APFS firmlinks: system-volume path → data-volume relative path (from `/usr/share/firmlinks`).
    public let firmlinks: [(source: String, target: String)]

    /// The read-write data volume of the boot volume group, normally `/System/Volumes/Data`.
    public var dataVolume: MountedVolume? {
        volumes.first { $0.mountPoint == "/System/Volumes/Data" }
    }

    public static func current() -> VolumeTable {
        VolumeTable(volumes: readMounts(), firmlinks: readFirmlinks())
    }

    public init(volumes: [MountedVolume], firmlinks: [(source: String, target: String)]) {
        self.volumes = volumes
        self.firmlinks = firmlinks
    }

    /// The volume whose mount point is the longest prefix of `path`.
    public func volume(containing path: String) -> MountedVolume? {
        volumes
            .filter { PathUtil.isAncestorOrEqual($0.mountPoint, of: path) }
            .max { $0.mountPoint.count < $1.mountPoint.count }
    }

    /// Device IDs of all volumes that share the APFS container of `path`.
    /// On a standard Mac scanning `/` this includes System, Data, VM (swap), Preboot and Update.
    public func containerDevices(for path: String) -> Set<dev_t> {
        guard let volume = volume(containing: path) else { return [] }
        guard let container = volume.container else { return [volume.deviceID] }
        return Set(volumes.filter { $0.container == container }.map(\.deviceID))
    }

    /// Data-volume paths that are reachable through a firmlink from inside `scanRoot`, and would
    /// therefore be counted twice. Returns absolute paths such as `/System/Volumes/Data/Users`.
    public func duplicateFirmlinkTargets(whenScanning scanRoot: String) -> Set<String> {
        guard let data = dataVolume else { return [] }
        // Scanning inside the data volume directly: nothing is reachable twice.
        if PathUtil.isAncestorOrEqual(data.mountPoint, of: scanRoot) { return [] }
        var result = Set<String>()
        for (source, target) in firmlinks where PathUtil.isAncestorOrEqual(scanRoot, of: source) {
            result.insert(data.mountPoint + "/" + target)
        }
        return result
    }

    private static func readMounts() -> [MountedVolume] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let mounts = buffer else { return [] }
        var result: [MountedVolume] = []
        for index in 0..<Int(count) {
            var entry = mounts[index]
            let mountPoint = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let device = withUnsafePointer(to: &entry.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let fsType = withUnsafePointer(to: &entry.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            var st = stat()
            guard lstat(mountPoint, &st) == 0 else { continue }
            result.append(
                MountedVolume(
                    mountPoint: mountPoint,
                    device: device,
                    fileSystem: fsType,
                    deviceID: st.st_dev,
                    isBrowsable: entry.f_flags & UInt32(MNT_DONTBROWSE) == 0
                ))
        }
        return result
    }

    private static func readFirmlinks() -> [(source: String, target: String)] {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// User-facing volumes, for a volume picker: the boot volume (as `/`) plus browsable local and external disks.
    public var userVisibleVolumes: [MountedVolume] {
        volumes.filter { volume in
            if volume.mountPoint == "/" { return true }
            return volume.isBrowsable && volume.mountPoint.hasPrefix("/Volumes/")
        }
    }
}
