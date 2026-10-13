import Foundation

/// Where SpaceKit finds its updates, and the purchase key that unlocks them. The app installs updates with
/// Sparkle from the website's appcast; the appcast lists a download only for a valid purchase key.
public enum UpdateCheck {
    public static let defaultServer = URL(string: "https://spacekit.studio")!

    /// The Sparkle appcast, carrying the purchase key when there is one.
    public static func appcastURL(server: URL = defaultServer, purchaseKey: String?) -> URL {
        let feed = server.appending(path: "appcast.xml")
        guard let purchaseKey, isPurchaseKey(purchaseKey) else { return feed }
        return feed.appending(queryItems: [URLQueryItem(name: "key", value: purchaseKey)])
    }

    /// The page where a buyer downloads the newest installer by hand: straight to the download with a
    /// purchase key, or the page that asks for one.
    public static func downloadPageURL(server: URL = defaultServer, purchaseKey: String?) -> URL {
        let page = server.appending(path: "update")
        guard let purchaseKey, isPurchaseKey(purchaseKey) else { return page }
        return page.appending(queryItems: [URLQueryItem(name: "session_id", value: purchaseKey)])
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
}
