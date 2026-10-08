import Foundation

/// Readable messages for errors from decoding YAML or JSON: where the problem is and what it is.
public enum DecodingErrorText {
    /// `jobs.[0].when.olderThan: '6m' means 6 minutes…` for decoding errors; the plain description otherwise.
    public static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        switch decoding {
        case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = keyPath(context.codingPath)
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "missing required key '\(keyPath(context.codingPath + [key]))'"
        @unknown default:
            return "\(error)"
        }
    }

    private static func keyPath(_ path: [CodingKey]) -> String {
        path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}
