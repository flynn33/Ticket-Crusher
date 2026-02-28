import Foundation
import SQLite3
import TicketCrusherCore

/// SQLite-backed diagnostics repository with retention, lookup, and text export support.
public final class SQLiteDiagnosticsRepository: DiagnosticsRepository {
    private let database: SQLiteDatabase
    private let retentionInterval: TimeInterval

    public init(database: SQLiteDatabase, retentionDays: Int = 30) {
        self.database = database
        self.retentionInterval = TimeInterval(max(1, retentionDays)) * 24 * 60 * 60
    }

    /// Persists one diagnostics event and enforces retention before insert.
    @discardableResult
    public func append(
        level: DiagnosticLogLevel,
        category: String,
        message: String,
        details: String?
    ) throws -> Int64 {
        try purgeExpiredIfNeeded()

        let statement = try database.prepare(
            """
            INSERT INTO logs(level, category, message, details, created_at)
            VALUES (?, ?, ?, ?, ?);
            """
        )
        defer { database.finalize(statement) }

        try database.bind(level.rawValue, at: 1, in: statement)
        try database.bind(normalizeCategory(category), at: 2, in: statement)
        try database.bind(normalizeMessage(message), at: 3, in: statement)
        try database.bind(normalizedDetails(details), at: 4, in: statement)
        try database.bind(Date().timeIntervalSince1970, at: 5, in: statement)

        _ = try database.step(statement)
        return database.lastInsertedRowID
    }

    /// Returns recent diagnostics records sorted by newest first.
    public func listRecent(limit: Int) throws -> [DiagnosticLogEntry] {
        try purgeExpiredIfNeeded()

        let statement = try database.prepare(
            """
            SELECT id, level, category, message, details, created_at
            FROM logs
            ORDER BY created_at DESC
            LIMIT ?;
            """
        )
        defer { database.finalize(statement) }

        try database.bind(Int64(max(1, limit)), at: 1, in: statement)

        var records: [DiagnosticLogEntry] = []
        while try database.step(statement) == SQLITE_ROW {
            records.append(mapLogEntry(from: statement))
        }

        return records
    }

    /// Returns one diagnostics record by ID when it exists.
    public func get(id: Int64) throws -> DiagnosticLogEntry? {
        try purgeExpiredIfNeeded()

        let statement = try database.prepare(
            """
            SELECT id, level, category, message, details, created_at
            FROM logs
            WHERE id = ?
            LIMIT 1;
            """
        )
        defer { database.finalize(statement) }

        try database.bind(id, at: 1, in: statement)
        guard try database.step(statement) == SQLITE_ROW else {
            return nil
        }

        return mapLogEntry(from: statement)
    }

    /// Deletes diagnostics records older than the supplied date.
    @discardableResult
    public func purge(olderThan date: Date) throws -> Int {
        let cutoff = date.timeIntervalSince1970

        let countStatement = try database.prepare(
            """
            SELECT COUNT(*)
            FROM logs
            WHERE created_at < ?;
            """
        )
        defer { database.finalize(countStatement) }
        try database.bind(cutoff, at: 1, in: countStatement)

        guard try database.step(countStatement) == SQLITE_ROW else {
            return 0
        }

        let count = Int(database.int64(at: 0, in: countStatement))
        guard count > 0 else { return 0 }

        let deleteStatement = try database.prepare(
            """
            DELETE FROM logs
            WHERE created_at < ?;
            """
        )
        defer { database.finalize(deleteStatement) }
        try database.bind(cutoff, at: 1, in: deleteStatement)
        _ = try database.step(deleteStatement)

        return count
    }

    /// Exports recent diagnostics to human-readable plain text.
    public func exportText(limit: Int) throws -> String {
        let entries = try listRecent(limit: limit)
        var lines: [String] = []

        lines.append("Ticket Crusher Diagnostic Export")
        lines.append("Generated: \(Date().formatted(date: .abbreviated, time: .standard))")
        lines.append("Retention: 30 days")
        lines.append("")

        if entries.isEmpty {
            lines.append("No diagnostic events recorded.")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        // Keep each entry to a compact header + optional details block for readable support exports.
        for entry in entries {
            lines.append(
                "[\(entry.createdAt.formatted(date: .abbreviated, time: .standard))] [\(entry.level.rawValue.uppercased())] [\(entry.category)] \(entry.message)"
            )
            if let details = normalizedDetails(entry.details) {
                lines.append(details)
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Applies retention policy by deleting records older than 30 days.
    private func purgeExpiredIfNeeded() throws {
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        _ = try purge(olderThan: cutoff)
    }

    /// Converts one query row into a diagnostics model value.
    private func mapLogEntry(from statement: OpaquePointer?) -> DiagnosticLogEntry {
        let level = DiagnosticLogLevel(rawValue: database.text(at: 1, in: statement) ?? "") ?? .info
        return DiagnosticLogEntry(
            id: database.int64(at: 0, in: statement),
            level: level,
            category: database.text(at: 2, in: statement) ?? "general",
            message: database.text(at: 3, in: statement) ?? "",
            details: normalizedDetails(database.text(at: 4, in: statement)),
            createdAt: Date(timeIntervalSince1970: database.double(at: 5, in: statement))
        )
    }

    /// Ensures categories are always non-empty for list filtering and display.
    private func normalizeCategory(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "general" : trimmed
    }

    /// Ensures message payloads are always non-empty before persistence.
    private func normalizeMessage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No message provided." : trimmed
    }

    /// Normalizes optional details payload by trimming empty values to nil.
    private func normalizedDetails(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Logging adapter that routes application/runtime log calls into diagnostics storage.
public final class SQLiteLogger: SupportLogger {
    private let diagnosticsRepository: DiagnosticsRepository
    private let category: String

    public init(diagnosticsRepository: DiagnosticsRepository, category: String = "general") {
        self.diagnosticsRepository = diagnosticsRepository
        self.category = category
    }

    /// Records an informational event for the configured logger category.
    public func log(_ message: String) {
        write(level: .info, message: message)
    }

    /// Records an error event for the configured logger category.
    public func error(_ message: String) {
        write(level: .error, message: message)
    }

    /// Persists one log event without allowing diagnostics failures to break app workflows.
    private func write(level: DiagnosticLogLevel, message: String) {
        do {
            try diagnosticsRepository.append(level: level, category: category, message: message, details: nil)
        } catch {
            // Logging must never fail the caller's primary workflow.
        }
    }
}
