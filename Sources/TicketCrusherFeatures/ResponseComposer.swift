import Foundation
import TicketCrusherCore

/// Converts KB article content and intake context into actionable troubleshooting guidance.
public struct PlaybookBuilder {
    public init() {}

    /// Extracts an ordered step list from a KB article body.
    public func steps(from article: KBArticle) -> [String] {
        let lines = article.bodyText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }

        let body = Array(lines.dropFirst())
        let source = body.isEmpty ? lines : body

        let steps = source
            .filter { line in
                !line.lowercased().hasPrefix("http")
            }
            .prefix(8)
            .map { line in
                line.replacingOccurrences(of: "•", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        if steps.isEmpty {
            return ["Open \(article.title) and follow the documented procedure in order."]
        }

        return Array(steps)
    }

    /// Generates likely causes based on intake context and article content signals.
    public func possibleCauses(from intake: TicketIntake, using article: KBArticle?) -> [String] {
        var causes: [String] = []

        if let app = intake.appInUseAtIssueTime, !app.isEmpty {
            causes.append("The issue may be specific to \(app) settings, cached credentials, or stale app state.")
        }

        if let ssid = intake.wifiSSID, !ssid.isEmpty {
            causes.append("Network restrictions or instability on SSID '\(ssid)' may be interrupting required services.")
        }

        if let serial = intake.normalizedSerial, serial.count < 10 {
            causes.append("The identifier appears abbreviated; a partial serial can cause record-mismatch during support triage.")
        }

        if let article {
            let lower = article.bodyText.lowercased()
            if lower.contains("password") || lower.contains("credential") {
                causes.append("Expired or unsynced credentials can block authentication flows.")
            }
            if lower.contains("cache") {
                causes.append("Corrupted local cache/session data may prevent the app from loading expected content.")
            }
            if lower.contains("vpn") || lower.contains("global protect") {
                causes.append("VPN tunnel instability or policy mismatch may prevent internal resource access.")
            }
        }

        if causes.isEmpty {
            causes.append("A transient client-side issue or configuration drift is likely; verify baseline settings and retry.")
        }

        return Array(Set(causes)).prefix(5).map { $0 }
    }
}

/// Renders structured response sections into the plain-text format used in UI and exports.
public struct ResponseComposer {
    public init() {}

    /// Builds a deterministic text response with steps first, then causes, missing info, and citations.
    public func render(response: BotResponse) -> String {
        var sections: [String] = []

        if !response.steps.isEmpty {
            sections.append("Troubleshooting steps")
            for (index, step) in response.steps.enumerated() {
                sections.append("\(index + 1). \(step)")
            }
        }

        sections.append("Possible causes")
        if response.possibleCauses.isEmpty {
            sections.append("- No specific causes identified yet.")
        } else {
            for cause in response.possibleCauses {
                sections.append("- \(cause)")
            }
        }

        if !response.neededInfo.isEmpty {
            sections.append("What I need from you")
            for item in response.neededInfo {
                sections.append("- \(item)")
            }
        }

        if !response.citations.isEmpty {
            sections.append("Sources")
            for citation in response.citations {
                sections.append("- \(citation.title) (\(citation.path))")
            }
        }

        return sections.joined(separator: "\n")
    }
}
