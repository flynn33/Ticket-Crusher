import Foundation

/// Supported severity levels for persisted diagnostic log events.
public enum DiagnosticLogLevel: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case error
    case critical
}

/// Normalized diagnostic event persisted for app, import, and runtime troubleshooting.
public struct DiagnosticLogEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let level: DiagnosticLogLevel
    public let category: String
    public let message: String
    public let details: String?
    public let createdAt: Date

    public init(
        id: Int64,
        level: DiagnosticLogLevel,
        category: String,
        message: String,
        details: String?,
        createdAt: Date
    ) {
        self.id = id
        self.level = level
        self.category = category
        self.message = message
        self.details = details
        self.createdAt = createdAt
    }
}

/// Contract for diagnostic persistence, retention, and export workflows.
public protocol DiagnosticsRepository {
    /// Writes one diagnostic event and returns its row identifier.
    @discardableResult
    func append(
        level: DiagnosticLogLevel,
        category: String,
        message: String,
        details: String?
    ) throws -> Int64

    /// Returns recent diagnostic events ordered newest first.
    func listRecent(limit: Int) throws -> [DiagnosticLogEntry]

    /// Returns one event by identifier when available.
    func get(id: Int64) throws -> DiagnosticLogEntry?

    /// Deletes events older than the provided timestamp and returns deleted row count.
    @discardableResult
    func purge(olderThan date: Date) throws -> Int

    /// Renders recent events as plain text suitable for `.txt` export.
    func exportText(limit: Int) throws -> String
}
