import Foundation
import TicketCrusherCore

/// Composes storage-layer dependencies (database, repositories, importer, diagnostics, logger) for app startup.
public struct StorageContainer {
    public let database: SQLiteDatabase
    public let kbRepository: KBRepository
    public let inventoryRepository: InventoryRepository
    public let importer: DataImporting
    public let ticketHistoryRepository: TicketHistoryRepository
    public let responseTemplateRepository: ResponseTemplateRepository
    public let diagnosticsRepository: DiagnosticsRepository
    public let logger: SupportLogger

    /// Initializes SQLite storage under Application Support for the provided bundle identifier.
    public init(bundleIdentifier: String = "com.jimdaley.ticketcrusher") throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let root = appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        let dbDirectory = root.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)

        let databaseURL = dbDirectory.appendingPathComponent("ticketcrusher.sqlite")
        let db = try SQLiteDatabase(databaseURL: databaseURL)
        try DatabaseMigrator(database: db).migrate()

        let diagnosticsRepository = SQLiteDiagnosticsRepository(database: db)
        let appLogger = SQLiteLogger(diagnosticsRepository: diagnosticsRepository, category: "app")
        let importerLogger = SQLiteLogger(diagnosticsRepository: diagnosticsRepository, category: "ingestion")

        self.database = db
        self.kbRepository = SQLiteKBRepository(database: db)
        self.inventoryRepository = SQLiteInventoryRepository(database: db)
        self.importer = DataPackImporter(database: db, logger: importerLogger)
        self.ticketHistoryRepository = SQLiteTicketHistoryRepository(database: db)
        self.responseTemplateRepository = SQLiteResponseTemplateRepository(database: db)
        self.diagnosticsRepository = diagnosticsRepository
        self.logger = appLogger
    }
}
