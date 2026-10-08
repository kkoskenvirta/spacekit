import Foundation

/// `~/.config/spacekit/config.yaml`. Every key is optional; missing keys take the defaults shown here.
/// The app's Settings window edits this same file, so hand edits and UI edits stay in sync.
public struct SpaceKitConfig: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var scan = ScanSettings()
    public var safety = SafetySettings()
    public var rules = RuleSettings()
    public var automation = AutomationSettings()
    public var jobs: [Job] = []
    public var ui = UISettings()

    public init() {}

    enum CodingKeys: String, CodingKey { case version, scan, safety, rules, automation, jobs, ui }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        scan = try c.decodeIfPresent(ScanSettings.self, forKey: .scan) ?? ScanSettings()
        safety = try c.decodeIfPresent(SafetySettings.self, forKey: .safety) ?? SafetySettings()
        rules = try c.decodeIfPresent(RuleSettings.self, forKey: .rules) ?? RuleSettings()
        automation = try c.decodeIfPresent(AutomationSettings.self, forKey: .automation) ?? AutomationSettings()
        jobs = try c.decodeIfPresent([Job].self, forKey: .jobs) ?? []
        ui = try c.decodeIfPresent(UISettings.self, forKey: .ui) ?? UISettings()
    }
}

public struct ScanSettings: Codable, Sendable, Equatable {
    /// What Explore scans by default.
    public var defaultPath: String = "/"
    /// Files below this size are summarised per folder instead of drawn individually.
    public var minFileSize: ByteCount = .mb(1)
    public var boundary: ScanOptions.Boundary = .container
    /// Paths or globs never scanned.
    public var exclude: [String] = []
    /// Worker threads; omit for the measured default.
    public var threads: Int?
    /// Where pattern rules look for projects (`node_modules`, `target`, …).
    public var devRoots: [String] = ScanSettings.defaultDevRoots

    public init() {}

    enum CodingKeys: String, CodingKey { case defaultPath, minFileSize, boundary, exclude, threads, devRoots }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultPath = try c.decodeIfPresent(String.self, forKey: .defaultPath) ?? "/"
        minFileSize = try c.decodeIfPresent(ByteCount.self, forKey: .minFileSize) ?? .mb(1)
        boundary = try c.decodeIfPresent(ScanOptions.Boundary.self, forKey: .boundary) ?? .container
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        threads = try c.decodeIfPresent(Int.self, forKey: .threads)
        devRoots = try c.decodeIfPresent([String].self, forKey: .devRoots) ?? ScanSettings.defaultDevRoots
    }

    public func options(markers: MarkerRegistry) -> ScanOptions {
        var options = ScanOptions()
        options.minFileSize = minFileSize.bytes
        options.boundary = boundary
        options.exclude = exclude
        if let threads, threads > 0 { options.threads = min(threads, 64) }
        options.markers = markers
        return options
    }
}

public struct SafetySettings: Codable, Sendable, Equatable {
    public enum TrashMode: String, Codable, Sendable, CaseIterable {
        /// Always move to the Trash.
        case always
        /// Follow each rule's `safety.trash` (regenerable caches may be deleted directly).
        case rules
    }

    public var trash: TrashMode = .always
    /// `trash: always`: nothing outside the Trash is deleted permanently. `CleanupExecutor` enforces it whatever the
    /// plan says; front ends read it only to explain what will happen.
    public var trashesEverything: Bool { trash == .always }
    /// Most an automatic run may remove.
    public var maxBytesPerRun: ByteCount = .gb(100)
    /// Extra paths that may never be removed (added to the built-in list, which can't be reduced).
    public var protectedPaths: [String] = []
    /// Extra executables rule commands may run. Code launchers are refused (`CommandTrust.isCodeLauncher`).
    public var allowedCommands: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case trash, maxBytesPerRun, protectedPaths, allowedCommands }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trash = try c.decodeIfPresent(TrashMode.self, forKey: .trash) ?? .always
        maxBytesPerRun = try c.decodeIfPresent(ByteCount.self, forKey: .maxBytesPerRun) ?? .gb(100)
        protectedPaths = try c.decodeIfPresent([String].self, forKey: .protectedPaths) ?? []
        allowedCommands = try c.decodeIfPresent([String].self, forKey: .allowedCommands) ?? []
    }
}

public struct RuleSettings: Codable, Sendable, Equatable {
    /// Rule ids to ignore.
    public var disabled: [String] = []
    /// Folders with your own rule files.
    public var directories: [String] = ["~/.config/spacekit/rules"]

    public init() {}

    enum CodingKeys: String, CodingKey { case disabled, directories }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disabled = try c.decodeIfPresent([String].self, forKey: .disabled) ?? []
        directories = try c.decodeIfPresent([String].self, forKey: .directories) ?? ["~/.config/spacekit/rules"]
    }
}

public struct AutomationSettings: Codable, Sendable, Equatable {
    public var notifications: Bool = true
    /// How often the background agent wakes up to check for due jobs, within `checkEveryRange`.
    public var checkEvery: Age = .hours(1)
    /// How often the agent takes a full storage snapshot for history ("what grew?"). `never` disables it.
    public var snapshot: Schedule? = .defaultSnapshot
    /// AI models used within this window count as active.
    public var activeModelWindow: Age = .days(90)

    /// Shortest and longest agent wake-up interval, in seconds. launchd needs a finite interval, and checking
    /// less than daily would make daily jobs run late.
    public static let checkEveryRange: ClosedRange<TimeInterval> = 300...86_400

    public init() {}

    enum CodingKeys: String, CodingKey { case notifications, checkEvery, snapshot, activeModelWindow }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        let every = try c.decodeIfPresent(Age.self, forKey: .checkEvery) ?? .hours(1)
        checkEvery = Age(seconds: min(max(every.seconds, Self.checkEveryRange.lowerBound), Self.checkEveryRange.upperBound))
        if let word = try? c.decodeIfPresent(String.self, forKey: .snapshot), ["never", "off", "none"].contains(word.lowercased()) {
            snapshot = nil
        } else {
            snapshot = try c.decodeIfPresent(Schedule.self, forKey: .snapshot) ?? .defaultSnapshot
        }
        activeModelWindow = try c.decodeIfPresent(Age.self, forKey: .activeModelWindow) ?? .days(90)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(notifications, forKey: .notifications)
        try c.encode(checkEvery, forKey: .checkEvery)
        if let snapshot { try c.encode(snapshot, forKey: .snapshot) } else { try c.encode("never", forKey: .snapshot) }
        try c.encode(activeModelWindow, forKey: .activeModelWindow)
    }
}

public struct UISettings: Codable, Sendable, Equatable {
    public enum Visualization: String, Codable, Sendable, CaseIterable { case sunburst, treemap }
    public enum ColorMode: String, Codable, Sendable, CaseIterable { case branch, category, safety, age }

    public var visualization: Visualization = .sunburst
    public var colorBy: ColorMode = .branch
    public var mapDepth: Int = 4

    public init() {}

    enum CodingKeys: String, CodingKey { case visualization, colorBy, mapDepth }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visualization = try c.decodeIfPresent(Visualization.self, forKey: .visualization) ?? .sunburst
        colorBy = try c.decodeIfPresent(ColorMode.self, forKey: .colorBy) ?? .branch
        mapDepth = min(max(try c.decodeIfPresent(Int.self, forKey: .mapDepth) ?? 4, 1), 8)
    }
}
