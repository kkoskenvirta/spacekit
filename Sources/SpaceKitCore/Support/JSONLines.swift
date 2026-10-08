import Foundation

/// Append-only JSON Lines files (the journal, storage history): one record per line, written under the file
/// lock. Lines that don't decode (a newer format, a torn write) are skipped rather than failing the read.
enum JSONLines {
    static func append<Record: Encodable>(_ records: [Record], to file: String) throws {
        guard !records.isEmpty else { return }
        let encoder = JSONEncoder.spaceKit
        let lines: [String] = try records.map { String(decoding: try encoder.encode($0), as: UTF8.self) + "\n" }
        try LockedFile.append(lines.joined(), to: file)
    }

    /// Records dated `since` or later (all when `nil`), in file order.
    static func read<Record: Decodable>(_ file: String, since: Date?, date: (Record) -> Date) -> [Record] {
        let decoder = JSONDecoder.spaceKit
        return LockedFile.readLines(file).compactMap { line in
            guard let record = try? decoder.decode(Record.self, from: Data(line.utf8)) else { return nil }
            if let since, date(record) < since { return nil }
            return record
        }
    }
}
