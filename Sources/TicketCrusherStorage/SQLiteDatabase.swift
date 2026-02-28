import Foundation
import SQLite3

/// SQLite C-API deallocator marker used when binding Swift strings.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Storage-layer SQLite error variants with readable descriptions.
public enum SQLiteError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
    case executeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "SQLite open failed: \(message)"
        case .prepareFailed(let message):
            return "SQLite prepare failed: \(message)"
        case .stepFailed(let message):
            return "SQLite step failed: \(message)"
        case .bindFailed(let message):
            return "SQLite bind failed: \(message)"
        case .executeFailed(let message):
            return "SQLite execute failed: \(message)"
        }
    }
}

/// Thin SQLite wrapper that centralizes statement lifecycle and typed binding helpers.
public final class SQLiteDatabase {
    private let databaseURL: URL
    private var handle: OpaquePointer?

    /// Opens the database file and applies baseline SQLite pragmas.
    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if sqlite3_open(databaseURL.path, &handle) != SQLITE_OK {
            throw SQLiteError.openFailed(lastErrorMessage)
        }

        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
    }

    /// Closes the SQLite connection when the wrapper is deallocated.
    deinit {
        sqlite3_close(handle)
    }

    /// Executes one or more SQL statements without result row handling.
    public func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let error = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw SQLiteError.executeFailed(error)
        }
    }

    /// Runs the given block in an immediate transaction with rollback on failure.
    public func inTransaction(_ block: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try block()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Compiles SQL into a prepared statement.
    public func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) != SQLITE_OK {
            throw SQLiteError.prepareFailed(lastErrorMessage)
        }
        guard let statement else {
            throw SQLiteError.prepareFailed("Prepared statement pointer was nil")
        }
        return statement
    }

    /// Finalizes and releases a prepared statement.
    public func finalize(_ statement: OpaquePointer?) {
        sqlite3_finalize(statement)
    }

    /// Steps a prepared statement once and validates result status.
    public func step(_ statement: OpaquePointer?) throws -> Int32 {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW || result == SQLITE_DONE {
            return result
        }
        throw SQLiteError.stepFailed(lastErrorMessage)
    }

    /// Resets a prepared statement for reuse and clears bound values.
    public func reset(_ statement: OpaquePointer?) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    /// Binds an optional string at the provided parameter index.
    public func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        if result != SQLITE_OK {
            throw SQLiteError.bindFailed(lastErrorMessage)
        }
    }

    /// Binds an optional 64-bit integer at the provided parameter index.
    public func bind(_ value: Int64?, at index: Int32, in statement: OpaquePointer?) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_int64(statement, index, value)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        if result != SQLITE_OK {
            throw SQLiteError.bindFailed(lastErrorMessage)
        }
    }

    /// Binds an optional double at the provided parameter index.
    public func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer?) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_double(statement, index, value)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        if result != SQLITE_OK {
            throw SQLiteError.bindFailed(lastErrorMessage)
        }
    }

    /// Reads an optional string value from the current row.
    public func text(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }

    /// Reads a 64-bit integer value from the current row.
    public func int64(at index: Int32, in statement: OpaquePointer?) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    /// Reads a double value from the current row.
    public func double(at index: Int32, in statement: OpaquePointer?) -> Double {
        sqlite3_column_double(statement, index)
    }

    /// Returns the row ID from the last successful insert.
    public var lastInsertedRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    /// Returns the on-disk path for the open SQLite database.
    public var databasePath: String {
        databaseURL.path
    }

    /// Returns the most recent SQLite error string from the open handle.
    private var lastErrorMessage: String {
        if let handle, let errorMessage = sqlite3_errmsg(handle) {
            return String(cString: errorMessage)
        }
        return "Unknown SQLite error"
    }
}
