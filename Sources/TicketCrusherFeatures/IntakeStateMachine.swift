import Foundation
import TicketCrusherCore

/// Intake states used to determine what user information is still required.
public enum IntakeWorkflowState: Equatable, Sendable {
    case unknownOrNonAppleDevice
    case missingSerial
    case missingIssue
    case missingAppOrSSID([IntakeField])
    case ready
}

/// Assessment result containing the current intake state and specific missing fields.
public struct IntakeAssessment: Sendable {
    public let state: IntakeWorkflowState
    public let missingFields: [IntakeField]

    public init(state: IntakeWorkflowState, missingFields: [IntakeField]) {
        self.state = state
        self.missingFields = missingFields
    }
}

/// Deterministic workflow validator for required support intake fields.
public struct IntakeStateMachine {
    public init() {}

    /// Evaluates intake values and returns the next workflow state.
    public func assess(_ intake: TicketIntake) -> IntakeAssessment {
        if intake.deviceType == .unknown || intake.deviceType == .nonApple {
            return IntakeAssessment(
                state: .unknownOrNonAppleDevice,
                missingFields: [.deviceType]
            )
        }

        if intake.normalizedSerial == nil {
            return IntakeAssessment(
                state: .missingSerial,
                missingFields: [.serialNumber]
            )
        }

        let issue = intake.issueDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if issue.count < 5 {
            return IntakeAssessment(
                state: .missingIssue,
                missingFields: [.issueDescription]
            )
        }

        var missingAppOrSSID: [IntakeField] = []

        let app = intake.appInUseAtIssueTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if app.isEmpty {
            missingAppOrSSID.append(.appInUseAtIssueTime)
        }

        let ssid = intake.wifiSSID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if ssid.isEmpty {
            missingAppOrSSID.append(.wifiSSID)
        }

        if !missingAppOrSSID.isEmpty {
            return IntakeAssessment(
                state: .missingAppOrSSID(missingAppOrSSID),
                missingFields: missingAppOrSSID
            )
        }

        return IntakeAssessment(state: .ready, missingFields: [])
    }

    /// Returns targeted follow-up prompts based on the current intake assessment.
    public func followUpPrompts(for assessment: IntakeAssessment) -> [String] {
        switch assessment.state {
        case .unknownOrNonAppleDevice:
            return [
                "What Apple device are you using (Mac, iPhone, or iPad), and what model if known?",
                "Please confirm this is Apple hardware before we continue with Apple-specific troubleshooting."
            ]
        case .missingSerial:
            return [
                "Please share the serial number. If you cannot access it, provide the best available device identifier."
            ]
        case .missingIssue:
            return [
                "Please describe the issue in detail, including any exact error text and what you expected to happen."
            ]
        case .missingAppOrSSID(let missing):
            var prompts: [String] = []
            if missing.contains(.appInUseAtIssueTime) {
                prompts.append("Which app were you using when the issue occurred?")
            }
            if missing.contains(.wifiSSID) {
                prompts.append("Which Wi-Fi SSID are you currently connected to?")
            }
            return prompts
        case .ready:
            return []
        }
    }
}
