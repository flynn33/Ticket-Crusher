import Foundation
import TicketCrusherCore

/// Normalizes raw KB content into structured searchable `KBArticle` records.
struct ArticleNormalizer {
    private static let knownApps = [
        "Outlook", "Teams", "GlobalProtect", "Horizon", "SharePoint", "OneDrive",
        "DUO", "Firefox", "Edge", "Workday", "Verkada", "Meraki", "Concur"
    ]

    /// Enriches article metadata by deriving tags, platforms, apps, and keyword tokens.
    static func normalize(
        id: String,
        title: String,
        bodyText: String,
        sourcePath: String,
        tags: [String]
    ) -> KBArticle {
        let titleWords = tokenize(title)
        let bodyWords = tokenize(bodyText)
        let pathWords = tokenize((sourcePath as NSString).lastPathComponent)

        let derivedTags = Set((tags + titleWords + pathWords).map { $0.lowercased() })
        let platforms = extractPlatforms(from: bodyText + " " + title + " " + sourcePath)
        let apps = extractApps(from: bodyText + " " + title)
        let keywords = Array(Set((titleWords + bodyWords).filter { $0.count > 2 })).sorted()

        return KBArticle(
            id: id,
            title: title,
            bodyText: bodyText,
            sourcePath: sourcePath,
            tags: Array(derivedTags).sorted(),
            platforms: platforms,
            apps: apps,
            keywords: keywords
        )
    }

    /// Parses likely procedural steps from article body text.
    static func parseSteps(from bodyText: String) -> [String] {
        let lines = bodyText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.isEmpty {
            return []
        }

        let bodyLines = Array(lines.dropFirst())
        if bodyLines.isEmpty {
            return ["Open the referenced support guide and follow the documented procedure."]
        }

        return bodyLines
            .filter { line in
                line.count > 2 && !line.lowercased().hasPrefix("http")
            }
            .prefix(10)
            .map { line in
                if line.range(of: "^\\d+[.)]", options: .regularExpression) != nil {
                    return line
                }
                return line.replacingOccurrences(of: "•", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    /// Extracts platform tags from free-form text.
    private static func extractPlatforms(from text: String) -> [String] {
        let lower = text.lowercased()
        var platforms: [String] = []
        if lower.contains("mac") || lower.contains("macos") {
            platforms.append("macOS")
        }
        if lower.contains("iphone") || lower.contains("ios") {
            platforms.append("iOS")
        }
        if lower.contains("ipad") || lower.contains("ipados") {
            platforms.append("iPadOS")
        }
        if lower.contains("windows") {
            platforms.append("Windows")
        }
        return platforms
    }

    /// Extracts known application names when present in text.
    private static func extractApps(from text: String) -> [String] {
        let lower = text.lowercased()
        return knownApps.filter { lower.contains($0.lowercased()) }
    }

    /// Tokenizes free-form text into lowercase alphanumeric fragments.
    private static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
