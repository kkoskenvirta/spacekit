import Foundation
import Synchronization

@testable import SpaceKitCore

/// A temporary directory tree for tests, removed on deinit.
final class TempTree {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("spacekit-tests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        // Resolve /var → /private/var so paths match what the scanner reports.
        root = PathUtil.realpath(base)!
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ relative: String) -> String { relative.isEmpty ? root : root + "/" + relative }

    @discardableResult
    func file(_ relative: String, bytes: Int, modified: Date? = nil) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: PathUtil.parent(full), withIntermediateDirectories: true)
        // Random bytes so the file system can't store it sparsely or compressed.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, bytes) }
        }
        try data.write(to: URL(fileURLWithPath: full))
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: full)
        }
        return full
    }

    func directory(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    /// Allocated size the way the scanner measures it.
    func allocated(_ relative: String) -> UInt64 { FileSize.allocated(atPath: path(relative)) ?? 0 }
}

func scan(_ path: String, minFileSize: UInt64 = 0, markers: [String] = [], configure: (inout ScanOptions) -> Void = { _ in }) throws
    -> ScanTree
{
    var options = ScanOptions()
    options.minFileSize = minFileSize
    options.markers = MarkerRegistry(names: markers)
    options.threads = 4
    configure(&options)
    return try Scanner(options: options).scan(path)
}

/// A volume table with no mounts, so tests don't depend on the machine's disks.
let emptyVolumes = VolumeTable(volumes: [], firmlinks: [])

func testGuard(home: String = "/Users/tester", protectedPaths: [String] = [], rules: [Rule] = [], root: Bool = false) -> SafetyGuard {
    SafetyGuard(home: home, userProtectedPaths: protectedPaths, protectedRules: rules, volumes: emptyVolumes, isRunningAsRoot: root)
}

/// Moves items into `home/.Trash` (renaming on collision, like Finder), so no test ever reaches the real Trash.
func sandboxTrash(home: String) -> @Sendable (String) throws -> String? {
    { path in
        let trash = home + "/.Trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        var destination = trash + "/" + PathUtil.lastComponent(path)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination) {
            destination = trash + "/\(PathUtil.lastComponent(path)) \(counter)"
            counter += 1
        }
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        return destination
    }
}

private let umaskLock = Mutex(())

/// Runs `body` with the process umask set to `mask`, then restores it. Tests run in parallel and the umask is
/// process-wide, so callers take turns. Use 077 rather than 002: files other tests write meanwhile come out
/// 0600 and folders 0700, which SpaceKit still trusts, while modes left to the umask still show up.
func withUmask<T>(_ mask: mode_t, _ body: () throws -> T) throws -> T {
    try umaskLock.withLock { _ in
        let previous = umask(mask)
        defer { umask(previous) }
        return try body()
    }
}

extension SafetyGuard {
    /// The guard's verdict on `path` as the disk has it now, with the facts a test names. Production code builds the
    /// target itself and must say what it knows about repositories and size; tests default them.
    func check(
        _ path: String, size: UInt64 = 0, rule: Rule? = nil, context: CleanupContext, isRepository: Bool = false,
        containsRepository: Bool = false
    ) -> SafetyVerdict {
        let target = RemovalTarget.at(
            path, home: home, size: size, isRepository: isRepository, containsRepository: containsRepository,
            probingRepositories: false)
        return evaluate(target, rule: rule, context: context)
    }
}

/// What a removal target would pin for `path`: its device and inode, not following a final symlink.
func identity(_ path: String) -> RemovalTarget.Identity? {
    var st = stat()
    return lstat(path, &st) == 0 ? RemovalTarget.Identity(st) : nil
}

/// A developer folder with `simctl` in `tree`, and a link to it like `/var/db/xcode_select_link`, for an executor's
/// `developerFolderLink`: which developer folder this Mac's xcode-select chose isn't what a test is about.
func standInDeveloperFolder(_ tree: TempTree) throws -> String {
    try tree.file("Developer/usr/bin/simctl", bytes: 16)
    let link = tree.path("xcode_select_link")
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tree.path("Developer"))
    return link
}
