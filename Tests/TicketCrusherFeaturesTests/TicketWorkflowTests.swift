import XCTest
@testable import TicketCrusherCore
@testable import TicketCrusherFeatures

/// Unit tests for parser, intake workflow sequencing, and response formatting order.
final class TicketWorkflowTests: XCTestCase {
    /// Ensures ticket header, annotations, and key intake fields are parsed correctly.
    func testTicketParserExtractsHeaderAnnotationsAndFields() {
        let parser = TicketParser(policy: .default())
        let message = """
        ##INC12345
        Device: MacBook Pro
        Serial: C02TEST12345
        App: Outlook
        SSID: TC-Corp
        // User reports issue started after password change
        Issue: Outlook keeps prompting for credentials
        """

        let result = parser.parse(message: message)

        XCTAssertTrue(result.isTicketMessage)
        XCTAssertEqual(result.intake.ticketNumber, "INC12345")
        XCTAssertEqual(result.intake.deviceType, .mac)
        XCTAssertEqual(result.intake.serialNumber, "C02TEST12345")
        XCTAssertEqual(result.intake.appInUseAtIssueTime, "Outlook")
        XCTAssertEqual(result.intake.wifiSSID, "TC-Corp")
        XCTAssertEqual(result.intake.annotations.first, "User reports issue started after password change")
    }

    /// Verifies expected state transitions from empty intake to workflow-ready.
    func testIntakeStateMachineSequence() {
        let machine = IntakeStateMachine()
        var intake = TicketIntake()

        var assessment = machine.assess(intake)
        XCTAssertEqual(assessment.state, .unknownOrNonAppleDevice)

        intake.deviceType = .mac
        assessment = machine.assess(intake)
        XCTAssertEqual(assessment.state, .missingSerial)

        intake.serialNumber = "C02TEST12345"
        assessment = machine.assess(intake)
        XCTAssertEqual(assessment.state, .missingIssue)

        intake.issueDescription = "Outlook authentication loop"
        assessment = machine.assess(intake)
        if case .missingAppOrSSID = assessment.state {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected missingAppOrSSID")
        }

        intake.appInUseAtIssueTime = "Outlook"
        intake.wifiSSID = "TC-Corp"
        assessment = machine.assess(intake)
        XCTAssertEqual(assessment.state, .ready)
    }

    /// Confirms response text renders troubleshooting steps before possible causes.
    func testResponseComposerOrdersSections() {
        let composer = ResponseComposer()
        let response = BotResponse(
            steps: ["Step one", "Step two"],
            possibleCauses: ["Cause one"],
            neededInfo: ["Need serial"],
            citations: [SourceCitation(title: "Article A", path: "kb/A.json")]
        )

        let text = composer.render(response: response)

        let stepsRange = text.range(of: "Troubleshooting steps")
        let causesRange = text.range(of: "Possible causes")

        XCTAssertNotNil(stepsRange)
        XCTAssertNotNil(causesRange)

        if let stepsRange, let causesRange {
            XCTAssertLessThan(stepsRange.lowerBound, causesRange.lowerBound)
        }
    }
}
