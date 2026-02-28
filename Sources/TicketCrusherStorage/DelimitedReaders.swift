import Foundation

/// Errors raised by lightweight delimited/text readers.
enum DelimitedReaderError: Error {
    case invalidHeader
    case decodeFailed
}

/// Reader for newline-delimited JSON files used by inventory and KB datasets.
struct JSONLReader {
    /// Returns non-empty lines from a JSONL file.
    static func lines(from url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Decodes each JSONL line into a dictionary object.
    static func jsonObjects(from url: URL) throws -> [[String: Any]] {
        let lines = try lines(from: url)
        var objects: [[String: Any]] = []
        objects.reserveCapacity(lines.count)

        for line in lines {
            guard let data = line.data(using: .utf8) else { continue }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DelimitedReaderError.decodeFailed
            }
            objects.append(json)
        }
        return objects
    }
}

/// Minimal CSV parser used for local inventory exports.
struct CSVReader {
    /// Reads CSV rows into `[header: value]` dictionaries.
    static func rows(from url: URL) throws -> [[String: String]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }

        guard let headerLine = lines.first else {
            throw DelimitedReaderError.invalidHeader
        }

        let headers = parseCSVLine(headerLine)
        guard !headers.isEmpty else {
            throw DelimitedReaderError.invalidHeader
        }

        var result: [[String: String]] = []
        for line in lines.dropFirst() {
            let values = parseCSVLine(line)
            var row: [String: String] = [:]
            for (idx, header) in headers.enumerated() {
                row[header] = idx < values.count ? values[idx] : ""
            }
            result.append(row)
        }

        return result
    }

    /// Parses one CSV line with basic quote escaping support.
    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "\"" {
                let next = line.index(after: index)
                if inQuotes && next < line.endIndex && line[next] == "\"" {
                    current.append("\"")
                    index = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(char)
            }
            index = line.index(after: index)
        }

        fields.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return fields
    }
}
