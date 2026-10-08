import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Config updates from front ends")
struct ConfigUpdateTests {
    @Test("An update applies one change to the file as it is now, keeping what others wrote since")
    func updateMergesIntoDisk() throws {
        let tree = try TempTree()
        let store = ConfigStore(file: tree.path("config.yaml"))
        var launched = SpaceKitConfig()
        launched.jobs = [Job(id: "a", name: "A", rules: ["x"])]
        try store.save(launched)

        // Another front end (the CLI) adds a job after the app loaded its copy.
        var onDisk = try store.load()
        onDisk.jobs.append(Job(id: "b", name: "B", rules: ["y"]))
        try store.save(onDisk)

        let saved = try store.update { $0.safety.maxBytesPerRun = .gb(5) }
        #expect(saved.jobs.map(\.id) == ["a", "b"])
        #expect(saved.safety.maxBytesPerRun == .gb(5))
        #expect(try store.load() == saved)
    }

    @Test("An update refuses to overwrite a config file that doesn't parse")
    func updateRefusesInvalidFile() throws {
        let tree = try TempTree()
        let file = tree.path("config.yaml")
        let broken = "safety:\n  trash: sometimes\n"
        try broken.write(toFile: file, atomically: true, encoding: .utf8)
        let store = ConfigStore(file: file)

        #expect(throws: ConfigError.self) { try store.update { $0.ui.mapDepth = 3 } }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == broken)
    }

    @Test("Adding a job to a config that doesn't parse keeps the person's protections on disk")
    func addJobRefusesInvalidFile() throws {
        let tree = try TempTree()
        let file = tree.path("config.yaml")
        let broken = "safety:\n  protectedPaths: [~/Work]\n  trash: sometimes\nrules:\n  disabled: [node.node-modules]\n"
        try broken.write(toFile: file, atomically: true, encoding: .utf8)
        let context = SpaceKitContext.load(paths: SpaceKitPaths(configFile: file, stateDirectory: tree.path("state")))
        #expect(context.configError != nil)

        #expect(throws: ConfigError.self) {
            try context.configStore.update { $0.upsertJob(Job(id: "new", name: "New", rules: ["x"]), replacing: nil) }
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == broken)
        #expect(!FileManager.default.fileExists(atPath: file + ".bak"))
    }

    @Test("An update without a config file starts from the defaults")
    func updateCreatesFile() throws {
        let tree = try TempTree()
        let store = ConfigStore(file: tree.path("nested/config.yaml"))
        let saved = try store.update { $0.ui.mapDepth = 6 }
        #expect(saved.ui.mapDepth == 6)
        #expect(try store.load().ui.mapDepth == 6)
    }

    @Test("A new job never takes an existing job's id")
    func newJobGetsUniqueID() {
        var config = SpaceKitConfig()
        config.jobs = [Job(id: "clean-downloads", name: "Old", paths: ["~/Downloads"]), Job(id: "clean-downloads-2", name: "Old 2", paths: ["~/x"])]

        let id = config.upsertJob(Job(id: "clean-downloads", name: "New", paths: ["~/Downloads"]), replacing: nil)

        #expect(id == "clean-downloads-3")
        #expect(config.jobs.map(\.id) == ["clean-downloads", "clean-downloads-2", "clean-downloads-3"])
        #expect(config.jobs[0].name == "Old")
    }

    @Test("Editing a job replaces it in place")
    func editReplacesJob() {
        var config = SpaceKitConfig()
        config.jobs = [Job(id: "a", name: "A", rules: ["x"]), Job(id: "b", name: "B", rules: ["y"])]
        var edited = config.jobs[0]
        edited.enabled = false

        let id = config.upsertJob(edited, replacing: "a")

        #expect(id == "a")
        #expect(config.jobs.map(\.id) == ["a", "b"])
        #expect(config.jobs[0].enabled == false)
    }

    @Test("Saving an edit of a job deleted elsewhere adds it back without clobbering another job")
    func editOfDeletedJobAppends() {
        var config = SpaceKitConfig()
        config.jobs = [Job(id: "b", name: "B", rules: ["y"])]

        let id = config.upsertJob(Job(id: "b", name: "Edited A", rules: ["x"]), replacing: "a")

        #expect(id == "b-2")
        #expect(config.jobs.map(\.name) == ["B", "Edited A"])
    }

    @Test("Unique ids fall back to a word when the name has no letters or digits")
    func uniqueIDForEmptySlug() {
        var config = SpaceKitConfig()
        #expect(config.uniqueJobID("") == "job")
        config.jobs = [Job(id: "job", name: "?", rules: ["x"])]
        #expect(config.uniqueJobID("") == "job-2")
    }
}

@Suite("Config files reached through a symlink")
struct ConfigSymlinkTests {
    @Test("A config symlink whose target is missing is a config error, not the defaults")
    func danglingLinkFailsClosed() throws {
        let tree = try TempTree()
        let file = tree.path("config/config.yaml")
        try tree.directory("config")
        try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: tree.path("dotfiles/config.yaml"))
        let store = ConfigStore(file: file)
        #expect(store.exists)
        #expect(throws: ConfigError.self) { try store.load() }

        let context = SpaceKitContext.load(paths: SpaceKitPaths(configFile: file, stateDirectory: tree.path("state")))
        #expect(context.configError != nil)
    }

    @Test("config init never replaces a symlink")
    func initKeepsLink() throws {
        let tree = try TempTree()
        let file = tree.path("config.yaml")
        try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: tree.path("missing.yaml"))
        let store = ConfigStore(file: file)
        #expect(try store.initialize() == false)
        #expect(throws: ConfigError.self) { try store.initialize(force: true) }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: file)) == tree.path("missing.yaml"))
    }

    @Test("Saving through a config symlink writes the file it points to and keeps the link")
    func saveKeepsLink() throws {
        let tree = try TempTree()
        let target = tree.path("dotfiles/config.yaml")
        try tree.directory("dotfiles")
        try "version: 1\n".write(toFile: target, atomically: true, encoding: .utf8)
        let file = tree.path("config.yaml")
        try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: target)

        try ConfigStore(file: file).update { $0.ui.mapDepth = 3 }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: file)) == target)
        #expect(try ConfigStore(file: target).load().ui.mapDepth == 3)
    }

    @Test("The backup of a symlinked config is a copy of the previous contents, not another link")
    func backupThroughLink() throws {
        let tree = try TempTree()
        let target = tree.path("dotfiles/config.yaml")
        try tree.directory("dotfiles")
        try "version: 1\nui:\n  mapDepth: 2\n".write(toFile: target, atomically: true, encoding: .utf8)
        let file = tree.path("config.yaml")
        try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: target)

        try ConfigStore(file: file).update { $0.ui.mapDepth = 3 }

        var st = stat()
        #expect(lstat(file + ".bak", &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG)
        #expect(try ConfigStore(file: file + ".bak").load().ui.mapDepth == 2)
    }
}
