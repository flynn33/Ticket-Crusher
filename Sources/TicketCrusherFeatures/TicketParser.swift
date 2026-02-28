import Foundation
import TicketCrusherCore

/// Parser output containing extracted intake fields and ticket-detection status.
public struct TicketParseResult: Sendable {
    public let intake: TicketIntake
    public let isTicketMessage: Bool

    public init(intake: TicketIntake, isTicketMessage: Bool) {
        self.intake = intake
        self.isTicketMessage = isTicketMessage
    }
}

/// Parses free-form user messages into structured ticket intake fields.
public struct TicketParser {
    private let policy: SupportWorkflowPolicy

    public init(policy: SupportWorkflowPolicy) {
        self.policy = policy
    }

    /// Parses one message into intake state by combining header detection, key-value pairs, and fallbacks.
    public func parse(message: String) -> TicketParseResult {
        let lines = message.components(separatedBy: .newlines)
        var intake = TicketIntake()

        if let headerLine = lines.first,
           let ticketNumber = extractTicketNumber(from: headerLine) {
            intake.ticketNumber = ticketNumber
        }

        var issueCandidateLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix(policy.commentPrefix) {
                let annotation = String(trimmed.dropFirst(policy.commentPrefix.count)).trimmingCharacters(in: .whitespaces)
                if !annotation.isEmpty {
                    intake.annotations.append(annotation)
                }
                continue
            }

            if extractTicketNumber(from: trimmed) != nil {
                continue
            }

            if let keyValue = parseKeyValue(line: trimmed) {
                assignKeyValue(keyValue, to: &intake)
                continue
            }

            issueCandidateLines.append(trimmed)
        }

        if intake.deviceType == .unknown {
            intake.deviceType = DeviceType.from(message)
        }

        if intake.issueDescription == nil {
            intake.issueDescription = issueCandidateLines.first(where: { !$0.hasPrefix(policy.commentPrefix) })
        }

        let isTicket = intake.ticketNumber != nil
        return TicketParseResult(intake: intake, isTicketMessage: isTicket)
    }

    /// Extracts the ticket number when the line begins with the configured ticket marker format.
    private func extractTicketNumber(from line: String) -> String? {
        let pattern = "^##\\s*(\\w+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(location: 0, length: line.utf16.count)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 1,
              let numberRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        return String(line[numberRange])
    }

    /// Parses `key: value` style lines into a normalized tuple.
    private func parseKeyValue(line: String) -> (String, String)? {
        let pattern = "^([A-Za-z _-]+):\\s*(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsRange = NSRange(location: 0, length: line.utf16.count)
        guard let match = regex.firstMatch(in: line, options: [], range: nsRange),
              let keyRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line)
        else {
            return nil
        }

        let key = String(line[keyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return nil
        }
        return (key, value)
    }

    /// Assigns a parsed key-value pair to the appropriate intake field.
    private func assignKeyValue(_ keyValue: (String, String), to intake: inout TicketIntake) {
        let key = keyValue.0.lowercased()
        let value = keyValue.1

        switch key {
        case "serial", "serial number", "sn":
            intake.serialNumber = value
        case "device", "device type", "model":
            intake.deviceType = DeviceType.from(value)
        case "issue", "issue description", "problem", "error":
            intake.issueDescription = value
        case "app", "application", "app in use":
            intake.appInUseAtIssueTime = value
        case "ssid", "wifi", "wi-fi", "wifi ssid":
            intake.wifiSSID = value
        case "os", "os version":
            intake.osVersion = value
        default:
            break
        }
    }
}
