import Foundation

extension Rule {
    /// The rule's `docs` link, if it is an `https` URL with a host. Rule files can come from anywhere, and a
    /// front end that opens a `file:` or custom-scheme URL would launch an app or open a local file instead of a page.
    public var docsURL: URL? {
        guard let docs, let url = URL(string: docs), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}
