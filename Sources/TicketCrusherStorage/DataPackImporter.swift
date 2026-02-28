import Foundation
import SQLite3
import TicketCrusherCore

/// Imports supported dataset files into SQLite, including KB and inventory normalization.
public final class DataPackImporter: DataImporting {
    /// Internal role classification used to route files through the correct importer.
    private enum DatasetRole {
        case workflowPolicy
        case knowledgeBase
        case inventory(InventorySourceType)
        case unsupported
    }

    /// File extensions accepted during dataset discovery.
    private static let supportedExtensions: Set<String> = [
        "jsonl", "json", "csv", "txt", "md", "markdown", "pdf", "docx", "doxs", "doc", "rtf", "xlsx", "xls", "log"
    ]

    /// Extensions treated as document-style knowledge-base sources.
    private static let knowledgeFileExtensions: Set<String> = [
        "txt", "md", "markdown", "pdf", "docx", "doxs", "doc", "rtf", "log"
    ]

    private let database: SQLiteDatabase
    private let logger: SupportLogger

    /// Creates a new importer bound to the provided SQLite database.
    public init(database: SQLiteDatabase, logger: SupportLogger = NullLogger()) {
        self.database = database
        self.logger = logger
    }

    /// Discovers files, determines changes, and imports supported data into normalized tables.
    public func importAll(from config: DataPackConfiguration) throws -> ImportReport {
        try DatabaseMigrator(database: database).migrate()

        let discoveredFiles = discoverDatasetFiles(from: config)
        guard !discoveredFiles.isEmpty else {
            return ImportReport(
                importedFiles: [],
                skippedFiles: ["No supported dataset files found in \(config.rootDirectory.path)"],
                recordCounts: [:]
            )
        }

        var fingerprints: [String: FileFingerprint] = [:]
        var changed = false
        var preflightSkipped: [String] = []

        // Preflight every candidate so we only run the heavy import path when data changed.
        for fileURL in discoveredFiles {
            do {
                let fingerprint = try FileFingerprint.make(for: fileURL)
                fingerprints[fileURL.path] = fingerprint
                if try isUnchanged(fileURL: fileURL, fingerprint: fingerprint) == false {
                    changed = true
                }
            } catch {
                logger.error("Failed to fingerprint \(fileURL.path): \(error.localizedDescription)")
                preflightSkipped.append(fileURL.lastPathComponent)
            }
        }

        if !changed {
            return ImportReport(
                importedFiles: [],
                skippedFiles: discoveredFiles.map(\.lastPathComponent) + preflightSkipped,
                recordCounts: [:]
            )
        }

        // Full refresh keeps data coherent when files are added/changed/removed.
        try database.execute("DELETE FROM kb_articles;")
        try database.execute("DELETE FROM inventory_records;")

        var importedFiles: [String] = []
        var skippedFiles: [String] = preflightSkipped
        var counts: [String: Int] = [:]

        // Route each file through the matching converter/importer based on role detection.
        for fileURL in discoveredFiles {
            guard let fingerprint = fingerprints[fileURL.path] else {
                skippedFiles.append(fileURL.lastPathComponent)
                continue
            }

            let role = detectRole(for: fileURL, workflowPolicyPath: config.workflowPolicyPath)
            do {
                let importedCount: Int
                switch role {
                case .workflowPolicy:
                    skippedFiles.append(fileURL.lastPathComponent)
                    continue
                case .knowledgeBase:
                    importedCount = try importKnowledgeBase(from: fileURL, clearExisting: false)
                case .inventory(let fallbackType):
                    importedCount = try importInventory(from: fileURL, fallbackType: fallbackType)
                case .unsupported:
                    skippedFiles.append(fileURL.lastPathComponent)
                    continue
                }

                // Record successful imports so incremental checks can skip unchanged files next run.
                try markImported(fileURL: fileURL, fingerprint: fingerprint)
                importedFiles.append(fileURL.lastPathComponent)
                counts[fileURL.lastPathComponent] = importedCount
            } catch {
                logger.error("Failed to import \(fileURL.path): \(error.localizedDescription)")
                skippedFiles.append(fileURL.lastPathComponent)
            }
        }

        if !importedFiles.isEmpty {
            try rebuildSearchIndexAndOptimizeDatabase()
        }

        return ImportReport(importedFiles: importedFiles, skippedFiles: skippedFiles, recordCounts: counts)
    }

    /// Imports KB articles from a single source file and writes them into `kb_articles`.
    private func importKnowledgeBase(from url: URL, clearExisting: Bool) throws -> Int {
        let articles = try loadKBArticles(from: url)
        if articles.isEmpty {
            return 0
        }

        let now = Date().timeIntervalSince1970
        var imported = 0

        try database.inTransaction {
            if clearExisting {
                try database.execute("DELETE FROM kb_articles;")
            }

            let statement = try database.prepare(
                """
                INSERT OR REPLACE INTO kb_articles (
                    id,
                    title,
                    body_text,
                    source_path,
                    tags_json,
                    platforms_json,
                    apps_json,
                    keywords_json,
                    tags_search,
                    updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            )
            defer { database.finalize(statement) }

            for article in articles {
                try database.bind(article.id, at: 1, in: statement)
                try database.bind(article.title, at: 2, in: statement)
                try database.bind(article.bodyText, at: 3, in: statement)
                try database.bind(article.sourcePath, at: 4, in: statement)
                try database.bind(Self.jsonString(article.tags), at: 5, in: statement)
                try database.bind(Self.jsonString(article.platforms), at: 6, in: statement)
                try database.bind(Self.jsonString(article.apps), at: 7, in: statement)
                try database.bind(Self.jsonString(article.keywords), at: 8, in: statement)
                try database.bind(article.tags.joined(separator: " "), at: 9, in: statement)
                try database.bind(now, at: 10, in: statement)
                _ = try database.step(statement)
                database.reset(statement)
                imported += 1
            }
        }

        return imported
    }

    /// Routes inventory imports by extension and supported conversion path.
    private func importInventory(from url: URL, fallbackType: InventorySourceType) throws -> Int {
        let ext = url.pathExtension.lowercased()

        if ext == "jsonl" {
            return try importInventoryJSONL(from: url, fallbackType: fallbackType)
        }

        if ext == "json" {
            return try importInventoryJSON(from: url, fallbackType: fallbackType)
        }

        if ext == "csv" {
            return try importInventoryCSV(from: url, fallbackType: fallbackType)
        }

        if ext == "xlsx" || ext == "xls" {
            let fallback = url.deletingLastPathComponent().appendingPathComponent("apple_intake_filtered.jsonl")
            if FileManager.default.fileExists(atPath: fallback.path) {
                return try importInventoryJSONL(from: fallback, fallbackType: .appleIntake)
            }
            throw NSError(
                domain: "TicketCrusherStorage",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "XLS/XLSX parsing requires a compatible JSONL export (for example apple_intake_filtered.jsonl)."]
            )
        }

        throw NSError(
            domain: "TicketCrusherStorage",
            code: 1000,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported inventory file format: \(url.pathExtension)"]
        )
    }

    /// Imports inventory records from newline-delimited JSON files.
    private func importInventoryJSONL(from url: URL, fallbackType: InventorySourceType) throws -> Int {
        let sourceName = url.lastPathComponent
        let objects = try JSONLReader.jsonObjects(from: url)
        let now = Date().timeIntervalSince1970
        var imported = 0

        try database.inTransaction {
            let deleteStatement = try database.prepare("DELETE FROM inventory_records WHERE source = ?;")
            try database.bind(sourceName, at: 1, in: deleteStatement)
            _ = try database.step(deleteStatement)
            database.finalize(deleteStatement)

            let insert = try database.prepare(
                """
                INSERT INTO inventory_records (
                    source,
                    source_type,
                    serial_number,
                    username,
                    display_name,
                    asset_tag,
                    phone_number,
                    os_version,
                    model,
                    raw_json,
                    updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            )
            defer { database.finalize(insert) }

            for object in objects {
                let typeText = (object["type"] as? String) ?? ""
                let sourceType = inventorySourceType(from: typeText, fallback: fallbackType)
                let source = (object["source"] as? String) ?? sourceName
                let record = (object["record"] as? [String: Any]) ?? object
                let normalized = normalizeInventoryRecord(record, sourceType: sourceType)

                try database.bind(source, at: 1, in: insert)
                try database.bind(sourceType.rawValue, at: 2, in: insert)
                try database.bind(normalized.serialNumber, at: 3, in: insert)
                try database.bind(normalized.username, at: 4, in: insert)
                try database.bind(normalized.displayName, at: 5, in: insert)
                try database.bind(normalized.assetTag, at: 6, in: insert)
                try database.bind(normalized.phoneNumber, at: 7, in: insert)
                try database.bind(normalized.osVersion, at: 8, in: insert)
                try database.bind(normalized.model, at: 9, in: insert)
                try database.bind(normalized.rawJSON, at: 10, in: insert)
                try database.bind(now, at: 11, in: insert)

                _ = try database.step(insert)
                database.reset(insert)
                imported += 1
            }
        }

        return imported
    }

    /// Imports inventory records from standard JSON arrays/objects.
    private func importInventoryJSON(from url: URL, fallbackType: InventorySourceType) throws -> Int {
        let sourceName = url.lastPathComponent
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)

        let records = extractRecordDictionaries(from: json)
        if records.isEmpty {
            return 0
        }

        let now = Date().timeIntervalSince1970
        var imported = 0

        try database.inTransaction {
            let deleteStatement = try database.prepare("DELETE FROM inventory_records WHERE source = ?;")
            try database.bind(sourceName, at: 1, in: deleteStatement)
            _ = try database.step(deleteStatement)
            database.finalize(deleteStatement)

            let insert = try database.prepare(
                """
                INSERT INTO inventory_records (
                    source,
                    source_type,
                    serial_number,
                    username,
                    display_name,
                    asset_tag,
                    phone_number,
                    os_version,
                    model,
                    raw_json,
                    updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            )
            defer { database.finalize(insert) }

            for record in records {
                let sourceType = inventorySourceType(
                    from: firstString(in: record, keys: ["type", "source_type"]) ?? "",
                    fallback: fallbackType
                )
                let normalized = normalizeInventoryRecord(record, sourceType: sourceType)

                try database.bind(sourceName, at: 1, in: insert)
                try database.bind(sourceType.rawValue, at: 2, in: insert)
                try database.bind(normalized.serialNumber, at: 3, in: insert)
                try database.bind(normalized.username, at: 4, in: insert)
                try database.bind(normalized.displayName, at: 5, in: insert)
                try database.bind(normalized.assetTag, at: 6, in: insert)
                try database.bind(normalized.phoneNumber, at: 7, in: insert)
                try database.bind(normalized.osVersion, at: 8, in: insert)
                try database.bind(normalized.model, at: 9, in: insert)
                try database.bind(normalized.rawJSON, at: 10, in: insert)
                try database.bind(now, at: 11, in: insert)

                _ = try database.step(insert)
                database.reset(insert)
                imported += 1
            }
        }

        return imported
    }

    /// Imports inventory records from CSV using header-based field mapping.
    private func importInventoryCSV(from url: URL, fallbackType: InventorySourceType) throws -> Int {
        let rows = try CSVReader.rows(from: url)
        let now = Date().timeIntervalSince1970
        let sourceName = url.lastPathComponent
        var imported = 0

        try database.inTransaction {
            let deleteStatement = try database.prepare("DELETE FROM inventory_records WHERE source = ?;")
            try database.bind(sourceName, at: 1, in: deleteStatement)
            _ = try database.step(deleteStatement)
            database.finalize(deleteStatement)

            let insert = try database.prepare(
                """
                INSERT INTO inventory_records (
                    source,
                    source_type,
                    serial_number,
                    username,
                    display_name,
                    asset_tag,
                    phone_number,
                    os_version,
                    model,
                    raw_json,
                    updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            )
            defer { database.finalize(insert) }

            for row in rows {
                let sourceType = inferredType(from: sourceName, fallback: fallbackType)
                let normalized = normalizeInventoryRecord(row, sourceType: sourceType)

                try database.bind(sourceName, at: 1, in: insert)
                try database.bind(sourceType.rawValue, at: 2, in: insert)
                try database.bind(normalized.serialNumber, at: 3, in: insert)
                try database.bind(normalized.username, at: 4, in: insert)
                try database.bind(normalized.displayName, at: 5, in: insert)
                try database.bind(normalized.assetTag, at: 6, in: insert)
                try database.bind(normalized.phoneNumber, at: 7, in: insert)
                try database.bind(normalized.osVersion, at: 8, in: insert)
                try database.bind(normalized.model, at: 9, in: insert)
                try database.bind(normalized.rawJSON, at: 10, in: insert)
                try database.bind(now, at: 11, in: insert)

                _ = try database.step(insert)
                database.reset(insert)
                imported += 1
            }
        }

        return imported
    }

    /// Loads KB articles from JSONL/JSON/doc formats and normalizes to a common model.
    private func loadKBArticles(from url: URL) throws -> [KBArticle] {
        if url.pathExtension.lowercased() == "jsonl" {
            let objects = try JSONLReader.jsonObjects(from: url)
            return objects.compactMap { obj in
                if isInventoryLikeRecord(obj) {
                    return nil
                }

                let id = (obj["id"] as? String) ?? UUID().uuidString
                let title = (obj["title"] as? String) ?? "Untitled"
                let text = (obj["text"] as? String) ?? (obj["body"] as? String) ?? ""
                let sourcePath = (obj["source_path"] as? String) ?? url.path
                let tags = (obj["tags"] as? [String]) ?? tagsFromFilename(url)

                return ArticleNormalizer.normalize(
                    id: id,
                    title: title,
                    bodyText: text,
                    sourcePath: sourcePath,
                    tags: tags
                )
            }
        }

        if url.pathExtension.lowercased() == "json" {
            return try loadKBArticlesFromJSONFile(url)
        }

        if Self.knowledgeFileExtensions.contains(url.pathExtension.lowercased()) {
            guard let text = try DocumentTextExtractor.extractText(from: url) else {
                return []
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            return [
                ArticleNormalizer.normalize(
                    id: UUID().uuidString,
                    title: url.deletingPathExtension().lastPathComponent,
                    bodyText: trimmed,
                    sourcePath: url.path,
                    tags: tagsFromFilename(url)
                )
            ]
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            return try contents.flatMap { child in
                try loadKBArticles(from: child)
            }
        }

        throw NSError(
            domain: "TicketCrusherStorage",
            code: 1002,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported KB input at \(url.path)"]
        )
    }

    /// Loads KB articles from a `.json` file that may use one of several schemas.
    private func loadKBArticlesFromJSONFile(_ url: URL) throws -> [KBArticle] {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)

        switch json {
        case let array as [[String: Any]]:
            return array.compactMap { jsonObjectToArticle($0, defaultSource: url.path, defaultTitle: url.deletingPathExtension().lastPathComponent) }
        case let object as [String: Any]:
            if let articles = object["articles"] as? [[String: Any]] {
                return articles.compactMap {
                    jsonObjectToArticle($0, defaultSource: url.path, defaultTitle: url.deletingPathExtension().lastPathComponent)
                }
            }

            if isInventoryLikeRecord(object) {
                return []
            }

            if let article = jsonObjectToArticle(object, defaultSource: url.path, defaultTitle: url.deletingPathExtension().lastPathComponent) {
                return [article]
            }
            return []
        default:
            return []
        }
    }

    /// Converts one JSON object into a normalized `KBArticle` when text content is available.
    private func jsonObjectToArticle(
        _ object: [String: Any],
        defaultSource: String,
        defaultTitle: String
    ) -> KBArticle? {
        let id = (object["id"] as? String) ?? UUID().uuidString
        let title = firstString(in: object, keys: ["title", "name", "topic"]) ?? defaultTitle
        let tags = (object["tags"] as? [String]) ?? tagsFromFilename(URL(fileURLWithPath: defaultSource))

        var text = firstString(in: object, keys: ["text", "body", "content", "description", "summary"]) ?? ""
        if text.isEmpty, let steps = object["steps"] as? [Any] {
            text = steps.map { String(describing: $0) }.joined(separator: "\n")
        }

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let jsonData = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
            text = String(data: jsonData, encoding: .utf8) ?? ""
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return ArticleNormalizer.normalize(
            id: id,
            title: title,
            bodyText: trimmed,
            sourcePath: defaultSource,
            tags: tags
        )
    }

    /// Collects preferred and auto-discovered dataset files under the configured root.
    private func discoverDatasetFiles(from config: DataPackConfiguration) -> [URL] {
        var urls: [URL] = []
        var seen: Set<String> = []

        let preferred = [
            config.knowledgeBasePath,
            config.managedMacsPath,
            config.managedMobilePath,
            config.assetsPath,
            config.appleIntakePath,
            config.workflowPolicyPath
        ]

        for url in preferred {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                urls.append(url.standardizedFileURL)
            }
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: config.rootDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let enumerator = FileManager.default.enumerator(
                at: config.rootDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            while let next = enumerator?.nextObject() as? URL {
                guard Self.supportedExtensions.contains(next.pathExtension.lowercased()) else {
                    continue
                }

                let key = next.standardizedFileURL.path
                if seen.insert(key).inserted {
                    urls.append(next.standardizedFileURL)
                }
            }
        }

        return urls.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    /// Determines whether a file should be treated as policy, KB, inventory, or unsupported input.
    private func detectRole(for url: URL, workflowPolicyPath: URL) -> DatasetRole {
        let standardized = url.standardizedFileURL.path
        let workflowPath = workflowPolicyPath.standardizedFileURL.path
        if standardized == workflowPath || url.lastPathComponent.lowercased().contains("cw-support-instructions") {
            return .workflowPolicy
        }

        let ext = url.pathExtension.lowercased()

        if Self.knowledgeFileExtensions.contains(ext) {
            return .knowledgeBase
        }

        if ext == "csv" || ext == "xlsx" || ext == "xls" {
            return .inventory(inferredType(from: url.lastPathComponent, fallback: .asset))
        }

        if ext == "jsonl" || ext == "json" {
            if looksLikeInventoryJSON(at: url) {
                return .inventory(inferredType(from: url.lastPathComponent, fallback: .asset))
            }
            return .knowledgeBase
        }

        return .unsupported
    }

    /// Heuristically checks whether JSON/JSONL content represents inventory-style records.
    private func looksLikeInventoryJSON(at url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()

        if ext == "jsonl" {
            guard let firstLine = try? JSONLReader.lines(from: url).first,
                  let data = firstLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data)
            else {
                return false
            }

            if let object = json as? [String: Any] {
                if let record = object["record"] as? [String: Any] {
                    return isInventoryLikeRecord(record)
                }
                return isInventoryLikeRecord(object)
            }
            return false
        }

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return false
        }

        if let object = json as? [String: Any] {
            if let record = object["record"] as? [String: Any] {
                return isInventoryLikeRecord(record)
            }
            if let records = object["records"] as? [[String: Any]], let first = records.first {
                return isInventoryLikeRecord(first)
            }
            if let dataArray = object["data"] as? [[String: Any]], let first = dataArray.first {
                return isInventoryLikeRecord(first)
            }
            return isInventoryLikeRecord(object)
        }

        if let array = json as? [[String: Any]], let first = array.first {
            return isInventoryLikeRecord(first)
        }

        return false
    }

    /// Heuristically checks dictionary keys/type hints for inventory semantics.
    private func isInventoryLikeRecord(_ dictionary: [String: Any]) -> Bool {
        let keys = Set(dictionary.keys.map { $0.lowercased() })
        let knownInventoryKeys: Set<String> = [
            "serial number",
            "serial_number",
            "computer name",
            "display name",
            "device phone number",
            "username",
            "user.name",
            "assettag",
            "asset tag",
            "operating system version",
            "os version",
            "model",
            "full name",
            "device/item",
            "scan"
        ]

        if !keys.intersection(knownInventoryKeys).isEmpty {
            return true
        }

        if let typeValue = dictionary["type"] as? String {
            let lower = typeValue.lowercased()
            if lower.contains("managed") || lower.contains("asset") || lower.contains("inventory") || lower.contains("intake") {
                return true
            }
        }

        return false
    }

    /// Extracts record dictionaries from supported JSON container shapes.
    private func extractRecordDictionaries(from json: Any) -> [[String: Any]] {
        switch json {
        case let record as [String: Any]:
            if let nested = record["record"] as? [String: Any] {
                return [nested]
            }
            if let records = record["records"] as? [[String: Any]] {
                return records
            }
            if let records = record["data"] as? [[String: Any]] {
                return records
            }
            return [record]
        case let array as [[String: Any]]:
            return array.map { item in
                if let nested = item["record"] as? [String: Any] {
                    return nested
                }
                return item
            }
        case let array as [Any]:
            return array.compactMap { item -> [String: Any]? in
                if let dict = item as? [String: Any] {
                    if let nested = dict["record"] as? [String: Any] {
                        return nested
                    }
                    return dict
                }
                return nil
            }
        default:
            return []
        }
    }

    /// Builds fallback tags from the source filename.
    private func tagsFromFilename(_ url: URL) -> [String] {
        url.deletingPathExtension()
            .lastPathComponent
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Checks the imports table to determine whether a file has changed since last import.
    private func isUnchanged(fileURL: URL, fingerprint: FileFingerprint) throws -> Bool {
        let statement = try database.prepare("SELECT sha256, modified_time FROM imports WHERE path = ?;")
        defer { database.finalize(statement) }

        try database.bind(fileURL.path, at: 1, in: statement)
        guard try database.step(statement) == SQLITE_ROW else {
            return false
        }

        let savedHash = database.text(at: 0, in: statement)
        let savedModified = database.double(at: 1, in: statement)

        return savedHash == fingerprint.sha256 && savedModified == fingerprint.modifiedTime
    }

    /// Persists successful import metadata for future change detection.
    private func markImported(fileURL: URL, fingerprint: FileFingerprint) throws {
        let statement = try database.prepare(
            """
            INSERT INTO imports (path, sha256, modified_time, imported_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                sha256 = excluded.sha256,
                modified_time = excluded.modified_time,
                imported_at = excluded.imported_at;
            """
        )
        defer { database.finalize(statement) }

        try database.bind(fileURL.path, at: 1, in: statement)
        try database.bind(fingerprint.sha256, at: 2, in: statement)
        try database.bind(fingerprint.modifiedTime, at: 3, in: statement)
        try database.bind(Date().timeIntervalSince1970, at: 4, in: statement)

        _ = try database.step(statement)
    }

    /// Infers inventory source type from filename hints.
    private func inferredType(from filename: String, fallback: InventorySourceType) -> InventorySourceType {
        let lower = filename.lowercased()
        if lower.contains("mac") { return .managedMac }
        if lower.contains("mobile") || lower.contains("iphone") || lower.contains("ipad") {
            return .managedMobile
        }
        if lower.contains("asset") { return .asset }
        if lower.contains("intake") || lower.contains("apple") { return .appleIntake }
        return fallback
    }

    /// Maps exported inventory type labels to canonical source-type enums.
    private func inventorySourceType(from typeText: String, fallback: InventorySourceType) -> InventorySourceType {
        let normalized = typeText.lowercased()
        if normalized.contains("managed_mac") {
            return .managedMac
        }
        if normalized.contains("managed_mobile") || normalized.contains("mobile") {
            return .managedMobile
        }
        if normalized.contains("asset") {
            return .asset
        }
        if normalized.contains("intake") {
            return .appleIntake
        }
        return fallback
    }

    /// Normalizes varied inventory schemas into the storage record shape.
    private func normalizeInventoryRecord(
        _ record: [String: Any],
        sourceType: InventorySourceType
    ) -> (
        serialNumber: String?,
        username: String?,
        displayName: String?,
        assetTag: String?,
        phoneNumber: String?,
        osVersion: String?,
        model: String?,
        rawJSON: String
    ) {
        let serial = firstString(in: record, keys: ["Serial Number", "serial_number", "Serial"])
        let username = firstString(in: record, keys: ["Username", "Full Name", "User.Name", "Associated To.Name", "Last Logged-in User"])
        let displayName = firstString(in: record, keys: ["Computer Name", "Display Name", "Name", "Device/Item"])
        let assetTag = firstString(in: record, keys: ["AssetTag", "Asset Tag", "Scan"])
        let phone = firstString(in: record, keys: ["Device Phone Number", "Phone", "phone_number"])
        let osVersion = firstString(in: record, keys: ["Operating System Version", "OS Version", "os_version"])
        let model = firstString(in: record, keys: ["Model", "Product.Product Name", "Device/Item", "Product Type.Product Type"])

        let jsonData = (try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])) ?? Data("{}".utf8)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        return (
            serialNumber: Self.normalizeIdentifier(serial),
            username: username,
            displayName: displayName,
            assetTag: assetTag,
            phoneNumber: phone,
            osVersion: osVersion,
            model: model ?? sourceType.rawValue,
            rawJSON: jsonString
        )
    }

    /// Returns the first non-empty string-like value from a dictionary across candidate keys.
    private func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] {
                if let string = value as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                } else if !(value is NSNull) {
                    let string = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !string.isEmpty { return string }
                }
            }
        }
        return nil
    }

    /// Normalizes lookup identifiers by removing spaces and uppercasing.
    private static func normalizeIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.replacingOccurrences(of: " ", with: "").uppercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Encodes string arrays as JSON text for database storage.
    private static func jsonString(_ values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Rebuilds FTS index and runs SQLite optimization after ingestion completes.
    private func rebuildSearchIndexAndOptimizeDatabase() throws {
        try database.execute("REINDEX;")
        try database.execute("ANALYZE;")
        try database.execute("PRAGMA optimize;")
    }
}
