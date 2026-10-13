import Foundation

/// A dotted release version such as `0.2.0`, compared number by number, so `0.10.0` is newer than `0.9.1`
/// and `1.0` equals `1.0.0`.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    /// Accepts one to four numbers separated by dots, with an optional leading `v`.
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            components.append(number)
        }
        self.components = components
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    private func padded(to count: Int) -> [Int] { components + Array(repeating: 0, count: max(0, count - components.count)) }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count).lexicographicallyPrecedes(rhs.padded(to: count))
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count) == rhs.padded(to: count)
    }
}

/// The newest release, as the website's `GET /api/updates/latest` describes it.
public struct ReleaseInfo: Decodable, Sendable, Equatable {
    public let version: String
    /// Release notes in plain text or Markdown, if the release has any.
    public let notes: String?
    /// Size of the installer in bytes.
    public let size: Int64?
    public let minimumSystemVersion: String?
    /// The website page that hands buyers the installer, relative to the update server.
    public let downloadPage: String?

    enum CodingKeys: String, CodingKey {
        case version, notes, size
        case minimumSystemVersion = "minimum_system_version"
        case downloadPage = "download_page"
    }
}

/// Checking spacekit.studio for a newer SpaceKit. The front end does the network request and decides when;
/// this decides what the answer means.
public enum UpdateCheck {
    public static let defaultServer = URL(string: "https://spacekit.studio")!

    public static func feedURL(server: URL = defaultServer) -> URL {
        server.appending(path: "api/updates/latest")
    }

    public static func decode(_ data: Data) throws -> ReleaseInfo {
        try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    /// Whether `release` is newer than the running `current` version and runs on this macOS. A version
    /// either side can't read never counts as an update.
    public static func isUpdate(
        _ release: ReleaseInfo, over current: String,
        system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        guard let new = AppVersion(release.version), let running = AppVersion(current), new > running else { return false }
        if let minimum = release.minimumSystemVersion.flatMap(AppVersion.init) {
            let installed = AppVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")!
            if installed < minimum { return false }
        }
        return true
    }

    /// The purchase key in what a buyer pasted: the key itself (a Stripe Checkout Session id) or the address
    /// of their download page, which carries it as `session_id`. Nil when there's no key in it.
    public static func purchaseKey(in text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: text), components.scheme != nil,
            let value = components.queryItems?.first(where: { $0.name == "session_id" || $0.name == "key" })?.value
        {
            return isPurchaseKey(value) ? value : nil
        }
        return isPurchaseKey(text) ? text : nil
    }

    public static func isPurchaseKey(_ text: String) -> Bool {
        guard text.hasPrefix("cs_live_") || text.hasPrefix("cs_test_") else { return false }
        let rest = text.dropFirst("cs_live_".count)
        return (10...250).contains(rest.count) && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The page where a buyer downloads the newest installer: straight to the download with a purchase key,
    /// or the page that asks for one.
    public static func downloadPageURL(server: URL = defaultServer, release: ReleaseInfo? = nil, purchaseKey: String?) -> URL {
        let page = release?.downloadPage.flatMap { URL(string: $0, relativeTo: server)?.absoluteURL } ?? server.appending(path: "update")
        guard let purchaseKey, isPurchaseKey(purchaseKey), var components = URLComponents(url: page, resolvingAgainstBaseURL: true)
        else { return page }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "session_id", value: purchaseKey)]
        return components.url ?? page
    }
}
