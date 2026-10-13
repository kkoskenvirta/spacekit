import AppKit
import Foundation
import Observation
import SpaceKitCore
import Sparkle

/// In-app updates through Sparkle. Sparkle checks the website's appcast (once a day unless turned off),
/// shows what's new, downloads the update, verifies its signature and replaces the app. The appcast lists a
/// download only for a valid purchase key, which buyers link from their download page or paste in Settings.
@Observable
@MainActor
final class UpdateController {
    /// For a `spacekit://activate` link, or a problem worth an alert.
    var message: String?

    /// The buyer's Stripe Checkout Session id, which unlocks updates on the website.
    private(set) var purchaseKey: String?

    var checksAutomatically: Bool {
        didSet { updater?.automaticallyChecksForUpdates = checksAutomatically }
    }

    var installsAutomatically: Bool {
        didSet { updater?.automaticallyDownloadsUpdates = installsAutomatically }
    }

    /// The version this copy reports, or nil when run from `swift run` (nothing to update).
    let currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var lastChecked: Date? { updater?.lastUpdateCheckDate }
    var canCheck: Bool { updater != nil }

    private let controller: SPUStandardUpdaterController?
    private let feed = FeedDelegate()
    private var updater: SPUUpdater? { controller?.updater }

    init() {
        purchaseKey = UserDefaults.standard.string(forKey: FeedDelegate.purchaseKeyDefault).flatMap(UpdateCheck.purchaseKey(in:))
        // Sparkle only works from an app bundle, not from `swift run`.
        controller =
            Bundle.main.bundleURL.pathExtension == "app"
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: feed, userDriverDelegate: nil) : nil
        checksAutomatically = controller?.updater.automaticallyChecksForUpdates ?? false
        installsAutomatically = controller?.updater.automaticallyDownloadsUpdates ?? false
    }

    func checkForUpdates() {
        guard let controller else {
            message = "This copy of SpaceKit wasn't built as an app, so it can't be updated."
            return
        }
        controller.checkForUpdates(nil)
    }

    /// The website's update page, for downloading the newest installer by hand.
    func openDownloadPage() {
        NSWorkspace.shared.open(UpdateCheck.downloadPageURL(server: FeedDelegate.server, purchaseKey: purchaseKey))
    }

    /// Stores a purchase key from what the buyer pasted; empty text unlinks. Returns false when there's no key in it.
    @discardableResult
    func setPurchaseKey(from text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            purchaseKey = nil
            UserDefaults.standard.removeObject(forKey: FeedDelegate.purchaseKeyDefault)
            return true
        }
        guard let key = UpdateCheck.purchaseKey(in: trimmed) else { return false }
        purchaseKey = key
        UserDefaults.standard.set(key, forKey: FeedDelegate.purchaseKeyDefault)
        return true
    }

    /// `spacekit://activate?key=…`, from the "Link to SpaceKit" button on the download page.
    func handle(_ url: URL) {
        guard url.scheme == "spacekit", url.host() == "activate" else { return }
        if setPurchaseKey(from: url.absoluteString) {
            message = "Your purchase is linked. SpaceKit installs updates for you from now on."
        } else {
            message = "That link doesn't contain a valid purchase key."
        }
    }
}

/// Gives Sparkle the appcast address with the purchase key. Sparkle calls it off the main actor, so it reads
/// the key from the defaults rather than from `UpdateController`.
private final class FeedDelegate: NSObject, SPUUpdaterDelegate {
    static let purchaseKeyDefault = "updates.purchaseKey"
    /// `defaults write dev.spacekit.app updates.server http://localhost:3000` points the app at a test site.
    static let serverDefault = "updates.server"

    static var server: URL {
        UserDefaults.standard.string(forKey: serverDefault).flatMap(URL.init(string:)) ?? UpdateCheck.defaultServer
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        let key = UserDefaults.standard.string(forKey: Self.purchaseKeyDefault)
        return UpdateCheck.appcastURL(server: Self.server, purchaseKey: key).absoluteString
    }
}
