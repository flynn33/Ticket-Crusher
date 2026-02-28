import Foundation

/// Supported device categories recognized by intake parsing and policy checks.
public enum DeviceType: String, Codable, CaseIterable, Sendable {
    case mac
    case iPhone
    case iPad
    case unknown
    case nonApple

    /// Attempts to infer a normalized device type from free-form text.
    public static func from(_ raw: String?) -> DeviceType {
        guard let raw else { return .unknown }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("mac") || normalized.contains("macbook") || normalized.contains("imac") {
            return .mac
        }
        if normalized.contains("iphone") {
            return .iPhone
        }
        if normalized.contains("ipad") {
            return .iPad
        }
        if normalized.isEmpty {
            return .unknown
        }
        return .nonApple
    }

    /// Indicates whether the parsed value represents Apple hardware.
    public var isAppleHardware: Bool {
        switch self {
        case .mac, .iPhone, .iPad:
            return true
        case .unknown, .nonApple:
            return false
        }
    }
}

/// Canonical required intake fields used by the ticket workflow.
public enum IntakeField: String, CaseIterable, Codable, Sendable {
    case deviceType = "device_type"
    case serialNumber = "serial_number"
    case issueDescription = "issue_description"
    case appInUseAtIssueTime = "app_in_use_at_time_of_issue"
    case wifiSSID = "wifi_ssid_connected_to"
}

/// Captured ticket intake state built incrementally across chat messages.
public struct TicketIntake: Codable, Equatable, Sendable {
    public var ticketNumber: String?
    public var deviceType: DeviceType
    public var serialNumber: String?
    public var issueDescription: String?
    public var appInUseAtIssueTime: String?
    public var wifiSSID: String?
    public var osVersion: String?
    public var annotations: [String]

    public init(
        ticketNumber: String? = nil,
        deviceType: DeviceType = .unknown,
        serialNumber: String? = nil,
        issueDescription: String? = nil,
        appInUseAtIssueTime: String? = nil,
        wifiSSID: String? = nil,
        osVersion: String? = nil,
        annotations: [String] = []
    ) {
        self.ticketNumber = ticketNumber
        self.deviceType = deviceType
        self.serialNumber = serialNumber
        self.issueDescription = issueDescription
        self.appInUseAtIssueTime = appInUseAtIssueTime
        self.wifiSSID = wifiSSID
        self.osVersion = osVersion
        self.annotations = annotations
    }

    /// Merges newly parsed intake values into the current session, preserving existing values first.
    public mutating func merge(_ other: TicketIntake) {
        if ticketNumber == nil { ticketNumber = other.ticketNumber }
        if deviceType == .unknown || deviceType == .nonApple { deviceType = other.deviceType }
        if (serialNumber ?? "").isEmpty { serialNumber = other.serialNumber }
        if (issueDescription ?? "").isEmpty { issueDescription = other.issueDescription }
        if (appInUseAtIssueTime ?? "").isEmpty { appInUseAtIssueTime = other.appInUseAtIssueTime }
        if (wifiSSID ?? "").isEmpty { wifiSSID = other.wifiSSID }
        if (osVersion ?? "").isEmpty { osVersion = other.osVersion }
        annotations.append(contentsOf: other.annotations)
    }

    /// Normalizes the serial number for deterministic record lookup.
    public var normalizedSerial: String? {
        guard let serialNumber else { return nil }
        let trimmed = serialNumber.replacingOccurrences(of: " ", with: "").uppercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Displayable citation used to reference source procedures in assistant responses.
public struct SourceCitation: Codable, Equatable, Hashable, Sendable {
    public let title: String
    public let path: String

    public init(title: String, path: String) {
        self.title = title
        self.path = path
    }
}

/// Normalized knowledge-base article model used by search and response generation.
public struct KBArticle: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let bodyText: String
    public let sourcePath: String
    public let tags: [String]
    public let platforms: [String]
    public let apps: [String]
    public let keywords: [String]

    public init(
        id: String,
        title: String,
        bodyText: String,
        sourcePath: String,
        tags: [String],
        platforms: [String],
        apps: [String],
        keywords: [String]
    ) {
        self.id = id
        self.title = title
        self.bodyText = bodyText
        self.sourcePath = sourcePath
        self.tags = tags
        self.platforms = platforms
        self.apps = apps
        self.keywords = keywords
    }
}

/// Search criteria for the KB repository, including optional ranking hints.
public struct KBSearchQuery: Sendable {
    public let text: String
    public let preferredDevice: DeviceType?
    public let preferredApp: String?

    public init(text: String, preferredDevice: DeviceType? = nil, preferredApp: String? = nil) {
        self.text = text
        self.preferredDevice = preferredDevice
        self.preferredApp = preferredApp
    }
}

/// Ranked KB search result wrapper.
public struct KBSearchResult: Sendable {
    public let article: KBArticle
    public let score: Double

    public init(article: KBArticle, score: Double) {
        self.article = article
        self.score = score
    }
}

/// Inventory dataset categories used by lookup and linking logic.
public enum InventorySourceType: String, Codable, Sendable {
    case managedMac
    case managedMobile
    case asset
    case appleIntake
    case unknown
}

/// Flattened inventory record persisted in SQLite.
public struct DeviceRecord: Codable, Equatable, Sendable {
    public let id: Int64
    public let source: String
    public let sourceType: InventorySourceType
    public let serialNumber: String?
    public let username: String?
    public let displayName: String?
    public let assetTag: String?
    public let phoneNumber: String?
    public let osVersion: String?
    public let model: String?
    public let rawJSON: String

    public init(
        id: Int64,
        source: String,
        sourceType: InventorySourceType,
        serialNumber: String?,
        username: String?,
        displayName: String?,
        assetTag: String?,
        phoneNumber: String?,
        osVersion: String?,
        model: String?,
        rawJSON: String
    ) {
        self.id = id
        self.source = source
        self.sourceType = sourceType
        self.serialNumber = serialNumber
        self.username = username
        self.displayName = displayName
        self.assetTag = assetTag
        self.phoneNumber = phoneNumber
        self.osVersion = osVersion
        self.model = model
        self.rawJSON = rawJSON
    }
}

/// Supported inventory lookup modes.
public enum LookupField: Sendable {
    case serialNumber
    case displayName
    case username
    case assetTag
    case phoneNumber
    case any
}

/// Parameters for querying inventory data.
public struct InventoryLookupQuery: Sendable {
    public let text: String
    public let field: LookupField

    public init(text: String, field: LookupField = .any) {
        self.text = text
        self.field = field
    }
}

/// Linked inventory view with confidence for cross-source correlation quality.
public struct LinkedDeviceContext: Sendable {
    public let records: [DeviceRecord]
    public let confidence: Double

    public init(records: [DeviceRecord], confidence: Double) {
        self.records = records
        self.confidence = confidence
    }
}

/// Structured assistant output before rendering to human-readable text.
public struct BotResponse: Sendable {
    public let steps: [String]
    public let possibleCauses: [String]
    public let neededInfo: [String]
    public let citations: [SourceCitation]

    public init(
        steps: [String],
        possibleCauses: [String],
        neededInfo: [String] = [],
        citations: [SourceCitation] = []
    ) {
        self.steps = steps
        self.possibleCauses = possibleCauses
        self.neededInfo = neededInfo
        self.citations = citations
    }
}

/// Full turn output containing rendered text plus underlying structured data.
public struct AssistantTurn: Sendable {
    public let text: String
    public let response: BotResponse
    public let intake: TicketIntake

    public init(text: String, response: BotResponse, intake: TicketIntake) {
        self.text = text
        self.response = response
        self.intake = intake
    }
}

/// Ticket-ready export payload schema used for JSON output.
public struct TicketExport: Codable, Sendable {
    public let ticketNumber: String?
    public let deviceType: String
    public let serialNumber: String?
    public let issueDescription: String?
    public let appInUse: String?
    public let wifiSSID: String?
    public let troubleshootingSteps: [String]
    public let possibleCauses: [String]
    public let requestedInfo: [String]
    public let citations: [SourceCitation]

    public init(ticketNumber: String?, intake: TicketIntake, response: BotResponse) {
        self.ticketNumber = ticketNumber
        self.deviceType = intake.deviceType.rawValue
        self.serialNumber = intake.serialNumber
        self.issueDescription = intake.issueDescription
        self.appInUse = intake.appInUseAtIssueTime
        self.wifiSSID = intake.wifiSSID
        self.troubleshootingSteps = response.steps
        self.possibleCauses = response.possibleCauses
        self.requestedInfo = response.neededInfo
        self.citations = response.citations
    }
}

/// Persisted triage ticket history record for tracking ticket state and resolution context.
public struct TriageTicketRecord: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let ticketNumber: String
    public let sourceText: String
    public let responseTemplate: String
    public let resolutionSummary: String?
    public let missingFields: [String]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: Int64,
        ticketNumber: String,
        sourceText: String,
        responseTemplate: String,
        resolutionSummary: String?,
        missingFields: [String],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.ticketNumber = ticketNumber
        self.sourceText = sourceText
        self.responseTemplate = responseTemplate
        self.resolutionSummary = resolutionSummary
        self.missingFields = missingFields
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Persisted user-defined response template used by the triage workflow.
public struct SavedResponseTemplate: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let body: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: Int64, name: String, body: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Input file configuration for the data import pipeline.
public struct DataPackConfiguration: Sendable {
    public let rootDirectory: URL
    public let knowledgeBasePath: URL
    public let managedMacsPath: URL
    public let managedMobilePath: URL
    public let assetsPath: URL
    public let appleIntakePath: URL
    public let workflowPolicyPath: URL

    public init(
        rootDirectory: URL,
        knowledgeBasePath: URL,
        managedMacsPath: URL,
        managedMobilePath: URL,
        assetsPath: URL,
        appleIntakePath: URL,
        workflowPolicyPath: URL
    ) {
        self.rootDirectory = rootDirectory
        self.knowledgeBasePath = knowledgeBasePath
        self.managedMacsPath = managedMacsPath
        self.managedMobilePath = managedMobilePath
        self.assetsPath = assetsPath
        self.appleIntakePath = appleIntakePath
        self.workflowPolicyPath = workflowPolicyPath
    }

    /// Builds a default configuration rooted at `<currentDirectory>/datasets`.
    public static func localDefault(currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> DataPackConfiguration {
        let root = currentDirectory.appendingPathComponent("datasets", isDirectory: true)
        return DataPackConfiguration(
            rootDirectory: root,
            knowledgeBasePath: root.appendingPathComponent("kb_corpus.jsonl"),
            managedMacsPath: root.appendingPathComponent("managed_macs.jsonl"),
            managedMobilePath: root.appendingPathComponent("managed_mobile_devices.jsonl"),
            assetsPath: root.appendingPathComponent("assets.jsonl"),
            appleIntakePath: root.appendingPathComponent("apple_intake_filtered.jsonl"),
            workflowPolicyPath: root.appendingPathComponent("cw-support-instructions.json")
        )
    }
}

/// Import result summary listing imported/skipped files and record counts.
public struct ImportReport: Sendable {
    public let importedFiles: [String]
    public let skippedFiles: [String]
    public let recordCounts: [String: Int]

    public init(importedFiles: [String], skippedFiles: [String], recordCounts: [String: Int]) {
        self.importedFiles = importedFiles
        self.skippedFiles = skippedFiles
        self.recordCounts = recordCounts
    }
}

/// Chat transcript message persisted in memory for the UI session.
public struct ChatMessage: Identifiable, Equatable, Sendable {
    /// Sender role for transcript rendering.
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public let text: String
    public let timestamp: Date
    public let citations: [SourceCitation]

    public init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date(), citations: [SourceCitation] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.citations = citations
    }
}
