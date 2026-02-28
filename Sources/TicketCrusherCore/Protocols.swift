import Foundation

/// Contract for knowledge-base search and article retrieval.
public protocol KBRepository {
    /// Executes ranked search for KB articles.
    func search(_ query: KBSearchQuery, limit: Int) throws -> [KBSearchResult]
    /// Returns a single article by unique identifier.
    func getArticle(id: String) throws -> KBArticle?
}

/// Contract for inventory lookup and cross-source context linking.
public protocol InventoryRepository {
    /// Finds inventory records matching the supplied query.
    func lookup(_ query: InventoryLookupQuery, limit: Int) throws -> [DeviceRecord]
    /// Correlates records across sources using serial and/or username.
    func linkedContext(serialNumber: String?, username: String?) throws -> LinkedDeviceContext
}

/// Contract for importing external datasets into local storage.
public protocol DataImporting {
    /// Imports all supported files from the provided data-pack configuration.
    func importAll(from config: DataPackConfiguration) throws -> ImportReport
}

/// Optional language-model abstraction for future response generation providers.
public protocol LLMProvider {
    /// Produces a model response for a prompt with additional context.
    func generate(prompt: String, context: String) async throws -> String
}

/// Interface for live Jamf inventory lookups.
public protocol JamfClient {
    /// Fetches managed computer details by serial number.
    func lookupComputer(serial: String) async throws -> [String: String]
    /// Fetches managed mobile-device details by serial number.
    func lookupMobileDevice(serial: String) async throws -> [String: String]
}

/// Interface for ServiceDesk Plus ticket operations.
public protocol SDPClient {
    /// Retrieves one ticket by ID.
    func getTicket(id: String) async throws -> [String: String]
    /// Appends a note to an existing ticket.
    func addNote(id: String, text: String) async throws
    /// Creates a new ticket and returns its identifier.
    func createTicket(payload: [String: String]) async throws -> String
}

/// Shared logging interface used by import and runtime services.
public protocol SupportLogger {
    /// Writes an informational event.
    func log(_ message: String)
    /// Writes an error event.
    func error(_ message: String)
}

/// Contract for persisting and retrieving triage ticket tracking records.
public protocol TicketHistoryRepository {
    /// Creates or updates a tracked ticket record.
    func upsert(
        ticketNumber: String,
        sourceText: String,
        responseTemplate: String,
        resolutionSummary: String?,
        missingFields: [String]
    ) throws

    /// Returns recently updated tracked tickets.
    func listRecent(limit: Int) throws -> [TriageTicketRecord]
}

/// Contract for user-managed response templates used by ticket triage.
public protocol ResponseTemplateRepository {
    /// Returns saved templates ordered by recent update.
    func listTemplates(limit: Int) throws -> [SavedResponseTemplate]

    /// Creates or updates a template keyed by name and returns the saved record.
    @discardableResult
    func saveTemplate(name: String, body: String) throws -> SavedResponseTemplate

    /// Deletes one saved template.
    func deleteTemplate(id: Int64) throws
}

/// No-op logger implementation used when persistent logging is not needed.
public struct NullLogger: SupportLogger {
    public init() {}
    public func log(_ message: String) {}
    public func error(_ message: String) {}
}
