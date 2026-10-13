import AppKit
import Foundation
import Observation
import SpaceKitCore

/// Asks spacekit.studio whether a newer SpaceKit exists, about once a day unless turned off, and sends buyers
/// to the page that hands them its installer. The request carries nothing but the app's version.
@Observable
@MainActor
final class UpdateController {
    /// The newest release, when it's newer than this copy and not skipped.
    private(set) var available: ReleaseInfo?
    private(set) var isChecking = false
    /// The answer to a check started from the menu or Settings, for an alert.
    var message: String?
    private(set) var lastChecked: Date?

    var checksAutomatically: Bool {
        didSet { defaults.set(checksAutomatically, forKey: Keys.automatic) }
    }

    /// The buyer's Stripe Checkout Session id, which unlocks downloads on the website.
    private(set) var purchaseKey: String?

    /// The version this copy reports: the bundle's, or nil when run from `swift run` (nothing to update).
    let currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    private let defaults = UserDefaults.standard
    private var loop: Task<Void, Never>?

    private enum Keys {
        static let automatic = "updates.checkAutomatically"
        static let lastChecked = "updates.lastChecked"
        static let skipped = "updates.skippedVersion"
        static let purchaseKey = "updates.purchaseKey"
        /// `defaults write dev.spacekit.app updates.server http://localhost:3000` points the app at a test site.
        static let server = "updates.server"
    }

    private static let interval: TimeInterval = 24 * 60 * 60

    init() {
        checksAutomatically = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
        purchaseKey = defaults.string(forKey: Keys.purchaseKey).flatMap(UpdateCheck.purchaseKey(in:))
    }

    var server: URL {
        defaults.string(forKey: Keys.server).flatMap(URL.init(string:)) ?? UpdateCheck.defaultServer
    }

    /// Checks now and then once a day while the app runs, when automatic checks are on.
    func start() {
        guard loop == nil, currentVersion != nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.checksAutomatically, Date().timeIntervalSince(self.lastChecked ?? .distantPast) >= Self.interval * 0.95 {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        guard let currentVersion else {
            if userInitiated { message = "This copy of SpaceKit wasn't built as an app, so it can't be updated." }
            return
        }
        isChecking = true
        defer { isChecking = false }
        var request = URLRequest(url: UpdateCheck.feedURL(server: server), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("SpaceKit/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try UpdateCheck.decode(data)
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Keys.lastChecked)
            if UpdateCheck.isUpdate(release, over: currentVersion) {
                if userInitiated || release.version != defaults.string(forKey: Keys.skipped) { available = release }
            } else {
                available = nil
                if userInitiated { message = "SpaceKit \(currentVersion) is the newest version." }
            }
        } catch {
            if userInitiated { message = "Couldn't check for updates. Check your internet connection and try again." }
        }
    }

    /// Opens the website's update page, which downloads the newest installer for a linked purchase.
    func download() {
        NSWorkspace.shared.open(UpdateCheck.downloadPageURL(server: server, release: available, purchaseKey: purchaseKey))
    }

    func skip() {
        guard let available else { return }
        defaults.set(available.version, forKey: Keys.skipped)
        self.available = nil
    }

    func dismiss() { available = nil }

    /// Stores a purchase key from what the buyer pasted. Returns false when there's no key in it.
    @discardableResult
    func setPurchaseKey(from text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            purchaseKey = nil
            defaults.removeObject(forKey: Keys.purchaseKey)
            return true
        }
        guard let key = UpdateCheck.purchaseKey(in: trimmed) else { return false }
        purchaseKey = key
        defaults.set(key, forKey: Keys.purchaseKey)
        return true
    }

    /// `spacekit://activate?key=…`, from the "Link to SpaceKit" button on the download page.
    func handle(_ url: URL) {
        guard url.scheme == "spacekit", url.host() == "activate" else { return }
        if setPurchaseKey(from: url.absoluteString) {
            message = "Your purchase is linked. SpaceKit can now download updates for you."
        } else {
            message = "That link doesn't contain a valid purchase key."
        }
    }
}
