import Foundation

/// Minimal RFC 4180 CSV parser: quoted fields, escaped quotes ("" inside
/// quotes), commas and newlines inside quotes, CRLF or LF line endings.
enum CSVParser {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex
        let end = text.endIndex

        while i < end {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < end, text[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\r":
                    break // swallow; the \n (if any) ends the row
                case "\n", "\r\n": // Swift groups CRLF into one Character
                    row.append(field)
                    field = ""
                    rows.append(row)
                    row = []
                default:
                    field.append(c)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    /// Parses text with a header row into dictionaries keyed by header name.
    /// Header names are trimmed; lookup is exact-case (callers lowercase if needed).
    static func parseRecords(_ text: String) -> [[String: String]] {
        let rows = parse(text)
        guard let header = rows.first else { return [] }
        let keys = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return rows.dropFirst().compactMap { row in
            guard row.count > 1 || (row.count == 1 && !row[0].isEmpty) else { return nil }
            var record: [String: String] = [:]
            for (index, key) in keys.enumerated() where index < row.count {
                record[key] = row[index]
            }
            return record
        }
    }
}
