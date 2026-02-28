import Foundation

/// Runtime policy model loaded from support workflow instruction JSON.
public struct SupportWorkflowPolicy: Sendable {
    public let supportedPlatforms: [String]
    public let deviceRequirement: String
    public let ticketPrefix: String
    public let commentPrefix: String
    public let requiredFields: [IntakeField]

    public init(
        supportedPlatforms: [String],
        deviceRequirement: String,
        ticketPrefix: String,
        commentPrefix: String,
        requiredFields: [IntakeField]
    ) {
        self.supportedPlatforms = supportedPlatforms
        self.deviceRequirement = deviceRequirement
        self.ticketPrefix = ticketPrefix
        self.commentPrefix = commentPrefix
        self.requiredFields = requiredFields
    }

    /// Returns the built-in fallback policy used when no external policy file is available.
    public static func `default`() -> SupportWorkflowPolicy {
        SupportWorkflowPolicy(
            supportedPlatforms: ["macOS", "iOS", "iPadOS"],
            deviceRequirement: "Must be Apple hardware",
            ticketPrefix: "##",
            commentPrefix: "//",
            requiredFields: [
                .deviceType,
                .serialNumber,
                .issueDescription,
                .appInUseAtIssueTime,
                .wifiSSID
            ]
        )
    }

    /// Decodes workflow policy from a JSON instructions file.
    public static func load(from url: URL) throws -> SupportWorkflowPolicy {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(InstructionDocument.self, from: data)

        let fields = decoded.intakeAndValidation.requiredDetails.compactMap { fieldName in
            IntakeField(rawValue: fieldName)
        }

        return SupportWorkflowPolicy(
            supportedPlatforms: decoded.scope.supportedPlatforms,
            deviceRequirement: decoded.scope.deviceRequirement,
            ticketPrefix: String(decoded.ticketDetection.triggerFormat.prefix(2)),
            commentPrefix: decoded.userAnnotations.commentPrefix,
            requiredFields: fields.isEmpty ? SupportWorkflowPolicy.default().requiredFields : fields
        )
    }
}

/// Top-level schema for `cw-support-instructions.json`.
private struct InstructionDocument: Decodable {
    let scope: Scope
    let ticketDetection: TicketDetection
    let userAnnotations: UserAnnotations
    let intakeAndValidation: IntakeAndValidation

    enum CodingKeys: String, CodingKey {
        case scope
        case ticketDetection = "ticket_detection"
        case userAnnotations = "user_annotations"
        case intakeAndValidation = "intake_and_validation"
    }
}

/// Scope block of the workflow policy schema.
private struct Scope: Decodable {
    let supportedPlatforms: [String]
    let deviceRequirement: String

    enum CodingKeys: String, CodingKey {
        case supportedPlatforms = "supported_platforms"
        case deviceRequirement = "device_requirement"
    }
}

/// Ticket trigger configuration block.
private struct TicketDetection: Decodable {
    let triggerFormat: String

    enum CodingKeys: String, CodingKey {
        case triggerFormat = "trigger_format"
    }
}

/// User annotation marker configuration block.
private struct UserAnnotations: Decodable {
    let commentPrefix: String

    enum CodingKeys: String, CodingKey {
        case commentPrefix = "comment_prefix"
    }
}

/// Intake requirements block.
private struct IntakeAndValidation: Decodable {
    let requiredDetails: [String]

    enum CodingKeys: String, CodingKey {
        case requiredDetails = "required_details"
    }
}
