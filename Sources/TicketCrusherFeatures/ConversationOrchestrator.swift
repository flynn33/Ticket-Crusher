import Foundation
import TicketCrusherCore

/// Coordinates parsing, intake validation, KB retrieval, and response composition for each user turn.
public final class ConversationOrchestrator {
    private let kbRepository: KBRepository
    private let inventoryRepository: InventoryRepository
    private let policy: SupportWorkflowPolicy
    private let parser: TicketParser
    private let stateMachine: IntakeStateMachine
    private let playbookBuilder: PlaybookBuilder
    private let composer: ResponseComposer

    private var sessionIntake: TicketIntake

    public init(
        kbRepository: KBRepository,
        inventoryRepository: InventoryRepository,
        policy: SupportWorkflowPolicy
    ) {
        self.kbRepository = kbRepository
        self.inventoryRepository = inventoryRepository
        self.policy = policy
        self.parser = TicketParser(policy: policy)
        self.stateMachine = IntakeStateMachine()
        self.playbookBuilder = PlaybookBuilder()
        self.composer = ResponseComposer()
        self.sessionIntake = TicketIntake()
    }

    /// Resets conversation state so a new ticket workflow starts from a clean intake.
    public func resetSession() {
        sessionIntake = TicketIntake()
    }

    /// Returns the currently accumulated intake payload for the active chat session.
    public func currentIntake() -> TicketIntake {
        sessionIntake
    }

    /// Handles one incoming user message and returns the assistant output turn.
    public func handle(message: String) throws -> AssistantTurn {
        let parse = parser.parse(message: message)
        sessionIntake.merge(parse.intake)

        let isTicketWorkflow = parse.isTicketMessage || sessionIntake.ticketNumber != nil

        if isTicketWorkflow {
            return try handleTicketWorkflow(message: message)
        }

        return try handleKnowledgeQuery(message: message)
    }

    /// Executes deterministic ticket workflow behavior when a ticket context is active.
    private func handleTicketWorkflow(message: String) throws -> AssistantTurn {
        let assessment = stateMachine.assess(sessionIntake)

        guard case .ready = assessment.state else {
            let neededInfo = stateMachine.followUpPrompts(for: assessment)
            let response = BotResponse(
                steps: [],
                possibleCauses: [],
                neededInfo: neededInfo,
                citations: []
            )
            let text = composer.render(response: response)
            return AssistantTurn(text: text, response: response, intake: sessionIntake)
        }

        let queryText = [
            sessionIntake.issueDescription,
            sessionIntake.appInUseAtIssueTime,
            sessionIntake.deviceType.rawValue,
            message
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        let results = try kbRepository.search(
            KBSearchQuery(
                text: queryText,
                preferredDevice: sessionIntake.deviceType,
                preferredApp: sessionIntake.appInUseAtIssueTime
            ),
            limit: 5
        )

        let topArticle = results.first?.article
        let citations = results.prefix(3).map {
            SourceCitation(title: $0.article.title, path: $0.article.sourcePath)
        }

        let steps: [String]
        if let topArticle {
            steps = playbookBuilder.steps(from: topArticle)
        } else {
            steps = [
                "I could not find a matching internal KB procedure for this issue.",
                "Escalate this ticket to Tier 2 with the intake details and captured error text."
            ]
        }

        var possibleCauses = playbookBuilder.possibleCauses(from: sessionIntake, using: topArticle)

        let linked = try inventoryRepository.linkedContext(
            serialNumber: sessionIntake.normalizedSerial,
            username: nil
        )
        if !linked.records.isEmpty {
            let primaryRecord = linked.records[0]
            let context = "Inventory context matched \(primaryRecord.sourceType.rawValue) record '\(primaryRecord.displayName ?? "unknown")' (confidence \(String(format: "%.2f", linked.confidence)))."
            possibleCauses.insert(context, at: 0)
        }

        let response = BotResponse(
            steps: steps,
            possibleCauses: Array(possibleCauses.prefix(6)),
            neededInfo: [],
            citations: citations
        )

        let text = composer.render(response: response)
        return AssistantTurn(text: text, response: response, intake: sessionIntake)
    }

    /// Executes ad-hoc KB search mode when no ticket workflow has been triggered.
    private func handleKnowledgeQuery(message: String) throws -> AssistantTurn {
        let guessDevice = DeviceType.from(message)

        let results = try kbRepository.search(
            KBSearchQuery(text: message, preferredDevice: guessDevice, preferredApp: nil),
            limit: 5
        )

        guard let top = results.first else {
            let response = BotResponse(
                steps: [
                    "I could not find this procedure in the internal KB.",
                    "Open a support escalation and include exact error text, device type, serial, app, and Wi-Fi SSID."
                ],
                possibleCauses: ["No direct KB match was found for the supplied query."],
                neededInfo: [],
                citations: []
            )
            return AssistantTurn(
                text: composer.render(response: response),
                response: response,
                intake: sessionIntake
            )
        }

        let citations = results.prefix(3).map {
            SourceCitation(title: $0.article.title, path: $0.article.sourcePath)
        }

        let response = BotResponse(
            steps: playbookBuilder.steps(from: top.article),
            possibleCauses: playbookBuilder.possibleCauses(from: sessionIntake, using: top.article),
            neededInfo: [],
            citations: citations
        )

        return AssistantTurn(
            text: composer.render(response: response),
            response: response,
            intake: sessionIntake
        )
    }
}
