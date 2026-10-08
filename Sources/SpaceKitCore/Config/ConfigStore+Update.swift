import Foundation

extension ConfigStore {
    /// Applies one change to the config file as it is on disk now, and saves it if it changed. Returns the config
    /// that is on disk afterwards.
    ///
    /// Front ends reach it through `SpaceKitContext.applying(_:)` instead of saving their copy, so a change made in the
    /// app doesn't drop jobs the CLI added since. A file that exists but doesn't parse is never overwritten: the
    /// `ConfigError` is thrown and the person's hand edits stay as they are.
    @discardableResult
    func update(_ change: (inout SpaceKitConfig) throws -> Void) throws -> SpaceKitConfig {
        try FileLock.withLock(for: file) {
            var config = try load()
            let before = config
            try change(&config)
            if config != before { try save(config) }
            return config
        }
    }
}

extension SpaceKitConfig {
    /// `base`, or `base-2`, `base-3`, … whichever no job uses yet. `ignoring` is a job id that doesn't count
    /// as taken (the job being replaced).
    public func uniqueJobID(_ base: String, ignoring: String? = nil) -> String {
        let base = base.isEmpty ? "job" : base
        let taken = Set(jobs.map(\.id)).subtracting(ignoring.map { [$0] } ?? [])
        var candidate = base
        var counter = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    /// Stores `job`: in place of the job with id `originalID` if there is one, otherwise as a new job. Neither
    /// ever overwrites another job; the job's id gets a numeric suffix instead. Returns the id it was stored under.
    @discardableResult
    public mutating func upsertJob(_ job: Job, replacing originalID: String?) -> String {
        var job = job
        if let originalID, let index = jobs.firstIndex(where: { $0.id == originalID }) {
            job.id = uniqueJobID(job.id, ignoring: originalID)
            jobs[index] = job
        } else {
            job.id = uniqueJobID(job.id)
            jobs.append(job)
        }
        return job.id
    }
}
