import Foundation

#if canImport(PDFKit)
import PDFKit
#endif

/// Extracts plain text from supported document formats for KB ingestion.
enum DocumentTextExtractor {
    /// Routes extraction logic by file extension.
    static func extractText(from url: URL) throws -> String? {
        let ext = url.pathExtension.lowercased()

        if ["txt", "md", "markdown", "log"].contains(ext) {
            return try String(contentsOf: url, encoding: .utf8)
        }

        if ext == "pdf" {
            return extractPDFText(from: url)
        }

        if ["docx", "doxs", "doc", "rtf"].contains(ext) {
            return try extractViaTextUtil(from: url)
        }

        return nil
    }

    /// Uses PDFKit to collect non-empty text from each page when available.
    private static func extractPDFText(from url: URL) -> String? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            return nil
        }

        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)

        for pageIndex in 0..<document.pageCount {
            if let text = document.page(at: pageIndex)?.string {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    pages.append(trimmed)
                }
            }
        }

        guard !pages.isEmpty else { return nil }
        return pages.joined(separator: "\n\n")
        #else
        return nil
        #endif
    }

    /// Uses the macOS `textutil` command to convert Office/RTF-like formats to plain text.
    private static func extractViaTextUtil(from url: URL) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }

        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return nil
    }
}
