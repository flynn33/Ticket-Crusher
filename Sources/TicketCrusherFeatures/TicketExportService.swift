import Foundation
import TicketCrusherCore

/// Formats assistant output into ticket-ready text and JSON artifacts.
public struct TicketExportService {
    public init() {}

    /// Exports a plain-text summary intended for direct ticket note insertion.
    public func exportSummary(intake: TicketIntake, response: BotResponse) -> String {
        var lines: [String] = []

        if let ticket = intake.ticketNumber {
            lines.append("Ticket: \(ticket)")
        }

        lines.append("Device Type: \(intake.deviceType.rawValue)")
        lines.append("Serial Number: \(intake.serialNumber ?? "Unknown")")
        lines.append("Issue: \(intake.issueDescription ?? "Not provided")")
        lines.append("App In Use: \(intake.appInUseAtIssueTime ?? "Not provided")")
        lines.append("Wi-Fi SSID: \(intake.wifiSSID ?? "Not provided")")
        lines.append("")

        lines.append("Troubleshooting steps")
        for (idx, step) in response.steps.enumerated() {
            lines.append("\(idx + 1). \(step)")
        }

        lines.append("")
        lines.append("Possible causes")
        for cause in response.possibleCauses {
            lines.append("- \(cause)")
        }

        if !response.neededInfo.isEmpty {
            lines.append("")
            lines.append("What I need from you")
            for item in response.neededInfo {
                lines.append("- \(item)")
            }
        }

        if !response.citations.isEmpty {
            lines.append("")
            lines.append("Sources")
            for citation in response.citations {
                lines.append("- \(citation.title) (\(citation.path))")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Exports the same session payload as compact JSON for automation or archival use.
    public func exportJSON(intake: TicketIntake, response: BotResponse) throws -> String {
        let payload = TicketExport(
            ticketNumber: intake.ticketNumber,
            intake: intake,
            response: response
        )
        let data = try JSONEncoder().encode(payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
