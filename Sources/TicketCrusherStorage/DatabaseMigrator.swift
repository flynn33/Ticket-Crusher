import Foundation
import SQLite3

/// Applies incremental SQLite schema migrations for storage-layer tables and indexes.
public final class DatabaseMigrator {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    /// Applies all pending migrations based on `PRAGMA user_version`.
    public func migrate() throws {
        let currentVersion = try schemaVersion()

        if currentVersion < 1 {
            try migrationV1()
            try setSchemaVersion(1)
        }

        if currentVersion < 2 {
            try migrationV2()
            try setSchemaVersion(2)
        }

        if currentVersion < 3 {
            try migrationV3()
            try setSchemaVersion(3)
        }
    }

    /// Reads the current SQLite schema version number.
    private func schemaVersion() throws -> Int {
        let statement = try database.prepare("PRAGMA user_version;")
        defer { database.finalize(statement) }
        guard try database.step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(database.int64(at: 0, in: statement))
    }

    /// Updates SQLite schema version after a successful migration.
    private func setSchemaVersion(_ version: Int) throws {
        try database.execute("PRAGMA user_version = \(version);")
    }

    /// Creates the initial schema for KB articles, inventory, imports, and logs.
    private func migrationV1() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS kb_articles (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            body_text TEXT NOT NULL,
            source_path TEXT NOT NULL,
            tags_json TEXT NOT NULL,
            platforms_json TEXT NOT NULL,
            apps_json TEXT NOT NULL,
            keywords_json TEXT NOT NULL,
            tags_search TEXT NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS kb_articles_fts USING fts5(
            title,
            body_text,
            tags,
            content='kb_articles',
            content_rowid='rowid'
        );

        CREATE TRIGGER IF NOT EXISTS kb_ai AFTER INSERT ON kb_articles BEGIN
            INSERT INTO kb_articles_fts(rowid, title, body_text, tags)
            VALUES (new.rowid, new.title, new.body_text, new.tags_search);
        END;

        CREATE TRIGGER IF NOT EXISTS kb_ad AFTER DELETE ON kb_articles BEGIN
            INSERT INTO kb_articles_fts(kb_articles_fts, rowid, title, body_text, tags)
            VALUES('delete', old.rowid, old.title, old.body_text, old.tags_search);
        END;

        CREATE TRIGGER IF NOT EXISTS kb_au AFTER UPDATE ON kb_articles BEGIN
            INSERT INTO kb_articles_fts(kb_articles_fts, rowid, title, body_text, tags)
            VALUES('delete', old.rowid, old.title, old.body_text, old.tags_search);
            INSERT INTO kb_articles_fts(rowid, title, body_text, tags)
            VALUES (new.rowid, new.title, new.body_text, new.tags_search);
        END;

        CREATE TABLE IF NOT EXISTS inventory_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL,
            source_type TEXT NOT NULL,
            serial_number TEXT,
            username TEXT,
            display_name TEXT,
            asset_tag TEXT,
            phone_number TEXT,
            os_version TEXT,
            model TEXT,
            raw_json TEXT NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_inventory_serial ON inventory_records(serial_number);
        CREATE INDEX IF NOT EXISTS idx_inventory_username ON inventory_records(username);
        CREATE INDEX IF NOT EXISTS idx_inventory_display_name ON inventory_records(display_name);
        CREATE INDEX IF NOT EXISTS idx_inventory_asset_tag ON inventory_records(asset_tag);
        CREATE INDEX IF NOT EXISTS idx_inventory_phone_number ON inventory_records(phone_number);

        CREATE TABLE IF NOT EXISTS imports (
            path TEXT PRIMARY KEY,
            sha256 TEXT NOT NULL,
            modified_time REAL NOT NULL,
            imported_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            level TEXT NOT NULL,
            message TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """

        try database.execute(sql)
    }

    /// Adds ticket-tracking and custom response-template tables.
    private func migrationV2() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS triage_tickets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ticket_number TEXT NOT NULL UNIQUE,
            source_text TEXT NOT NULL,
            response_template TEXT NOT NULL,
            resolution_summary TEXT,
            missing_fields_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_triage_tickets_updated_at ON triage_tickets(updated_at);

        CREATE TABLE IF NOT EXISTS response_templates (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            body TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_response_templates_updated_at ON response_templates(updated_at);
        """

        try database.execute(sql)
    }

    /// Extends diagnostics schema with categories/details and log-retention indexes.
    private func migrationV3() throws {
        let sql = """
        ALTER TABLE logs ADD COLUMN category TEXT NOT NULL DEFAULT 'general';
        ALTER TABLE logs ADD COLUMN details TEXT;
        CREATE INDEX IF NOT EXISTS idx_logs_created_at ON logs(created_at);
        CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level);
        """

        do {
            try database.execute(sql)
        } catch {
            // Older databases may already contain one or both columns; apply idempotent fallbacks.
            try applyLogSchemaFallbacks()
        }
    }

    /// Applies idempotent diagnostics schema updates when multi-statement ALTER execution partially succeeds.
    private func applyLogSchemaFallbacks() throws {
        if try !columnExists(named: "category", in: "logs") {
            try database.execute("ALTER TABLE logs ADD COLUMN category TEXT NOT NULL DEFAULT 'general';")
        }

        if try !columnExists(named: "details", in: "logs") {
            try database.execute("ALTER TABLE logs ADD COLUMN details TEXT;")
        }

        try database.execute("CREATE INDEX IF NOT EXISTS idx_logs_created_at ON logs(created_at);")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level);")
    }

    /// Returns whether a table already includes a specific column.
    private func columnExists(named columnName: String, in tableName: String) throws -> Bool {
        let statement = try database.prepare("PRAGMA table_info(\(tableName));")
        defer { database.finalize(statement) }

        while try database.step(statement) == SQLITE_ROW {
            if database.text(at: 1, in: statement) == columnName {
                return true
            }
        }

        return false
    }
}
