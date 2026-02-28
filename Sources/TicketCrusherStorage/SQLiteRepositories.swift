import Foundation
import SQLite3
import TicketCrusherCore

/// SQLite-backed implementation of KB retrieval with FTS ranking and domain-aware reranking.
public final class SQLiteKBRepository: KBRepository {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    /// Searches FTS-backed KB data and applies device/app preference boosts.
    public func search(_ query: KBSearchQuery, limit: Int) throws -> [KBSearchResult] {
        let tokens = tokenize(query.text)
        guard !tokens.isEmpty else { return [] }

        let sql = """
        SELECT
            kb.id,
            kb.title,
            kb.body_text,
            kb.source_path,
            kb.tags_json,
            kb.platforms_json,
            kb.apps_json,
            kb.keywords_json,
            bm25(kb_articles_fts) AS rank
        FROM kb_articles_fts
        JOIN kb_articles kb ON kb_articles_fts.rowid = kb.rowid
        WHERE kb_articles_fts MATCH ?
        ORDER BY rank ASC
        LIMIT ?;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        try database.bind(ftsQuery(from: tokens), at: 1, in: statement)
        try database.bind(Int64(limit), at: 2, in: statement)

        var results: [KBSearchResult] = []

        while try database.step(statement) == SQLITE_ROW {
            let article = KBArticle(
                id: database.text(at: 0, in: statement) ?? "",
                title: database.text(at: 1, in: statement) ?? "",
                bodyText: database.text(at: 2, in: statement) ?? "",
                sourcePath: database.text(at: 3, in: statement) ?? "",
                tags: decodeArray(database.text(at: 4, in: statement)),
                platforms: decodeArray(database.text(at: 5, in: statement)),
                apps: decodeArray(database.text(at: 6, in: statement)),
                keywords: decodeArray(database.text(at: 7, in: statement))
            )

            let rank = database.double(at: 8, in: statement)
            let score = rerankedScore(
                rawRank: rank,
                article: article,
                preferredDevice: query.preferredDevice,
                preferredApp: query.preferredApp
            )

            results.append(KBSearchResult(article: article, score: score))
        }

        return results.sorted { $0.score > $1.score }
    }

    /// Fetches a single KB article by ID from the relational table.
    public func getArticle(id: String) throws -> KBArticle? {
        let statement = try database.prepare(
            """
            SELECT id, title, body_text, source_path, tags_json, platforms_json, apps_json, keywords_json
            FROM kb_articles
            WHERE id = ?
            LIMIT 1;
            """
        )
        defer { database.finalize(statement) }

        try database.bind(id, at: 1, in: statement)

        guard try database.step(statement) == SQLITE_ROW else {
            return nil
        }

        return KBArticle(
            id: database.text(at: 0, in: statement) ?? "",
            title: database.text(at: 1, in: statement) ?? "",
            bodyText: database.text(at: 2, in: statement) ?? "",
            sourcePath: database.text(at: 3, in: statement) ?? "",
            tags: decodeArray(database.text(at: 4, in: statement)),
            platforms: decodeArray(database.text(at: 5, in: statement)),
            apps: decodeArray(database.text(at: 6, in: statement)),
            keywords: decodeArray(database.text(at: 7, in: statement))
        )
    }

    /// Builds an FTS query string from normalized search tokens.
    private func ftsQuery(from tokens: [String]) -> String {
        tokens.map { "\($0)*" }.joined(separator: " AND ")
    }

    /// Tokenizes and bounds search input for stable FTS query size.
    private func tokenize(_ text: String) -> [String] {
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        return Array(tokens.prefix(8))
    }

    /// Decodes JSON array columns stored as text.
    private func decodeArray(_ json: String?) -> [String] {
        guard
            let json,
            let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return decoded
    }

    /// Adjusts raw FTS rank with preference boosts for platform and app hints.
    private func rerankedScore(
        rawRank: Double,
        article: KBArticle,
        preferredDevice: DeviceType?,
        preferredApp: String?
    ) -> Double {
        var score = 1 / (abs(rawRank) + 1)

        if let preferredDevice {
            let deviceToken: String
            switch preferredDevice {
            case .mac:
                deviceToken = "macos"
            case .iPhone:
                deviceToken = "ios"
            case .iPad:
                deviceToken = "ipados"
            case .unknown, .nonApple:
                deviceToken = ""
            }

            if !deviceToken.isEmpty {
                let matched = article.platforms.contains { $0.lowercased().contains(deviceToken) }
                if matched { score += 0.35 }
            }
        }

        if let preferredApp {
            let matched = article.apps.contains { $0.caseInsensitiveCompare(preferredApp) == .orderedSame }
            if matched { score += 0.25 }
        }

        return score
    }
}

/// SQLite-backed implementation of inventory lookup and record linking.
public final class SQLiteInventoryRepository: InventoryRepository {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    /// Performs scoped or broad lookup across normalized inventory columns.
    public func lookup(_ query: InventoryLookupQuery, limit: Int) throws -> [DeviceRecord] {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let wildcard = "%\(trimmed)%"
        let normalizedSerial = trimmed.replacingOccurrences(of: " ", with: "").uppercased()

        let sql = """
        SELECT id, source, source_type, serial_number, username, display_name, asset_tag, phone_number, os_version, model, raw_json
        FROM inventory_records
        WHERE
            (? = 'serial' AND serial_number = ?) OR
            (? = 'display' AND display_name LIKE ?) OR
            (? = 'username' AND username LIKE ?) OR
            (? = 'asset' AND asset_tag LIKE ?) OR
            (? = 'phone' AND phone_number LIKE ?) OR
            (? = 'any' AND (
                serial_number = ? OR
                display_name LIKE ? OR
                username LIKE ? OR
                asset_tag LIKE ? OR
                phone_number LIKE ?
            ))
        LIMIT ?;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        let fieldToken = fieldToken(for: query.field)
        try database.bind(fieldToken, at: 1, in: statement)
        try database.bind(normalizedSerial, at: 2, in: statement)
        try database.bind(fieldToken, at: 3, in: statement)
        try database.bind(wildcard, at: 4, in: statement)
        try database.bind(fieldToken, at: 5, in: statement)
        try database.bind(wildcard, at: 6, in: statement)
        try database.bind(fieldToken, at: 7, in: statement)
        try database.bind(wildcard, at: 8, in: statement)
        try database.bind(fieldToken, at: 9, in: statement)
        try database.bind(wildcard, at: 10, in: statement)
        try database.bind(fieldToken, at: 11, in: statement)
        try database.bind(normalizedSerial, at: 12, in: statement)
        try database.bind(wildcard, at: 13, in: statement)
        try database.bind(wildcard, at: 14, in: statement)
        try database.bind(wildcard, at: 15, in: statement)
        try database.bind(wildcard, at: 16, in: statement)
        try database.bind(Int64(limit), at: 17, in: statement)

        var results: [DeviceRecord] = []
        while try database.step(statement) == SQLITE_ROW {
            let record = DeviceRecord(
                id: database.int64(at: 0, in: statement),
                source: database.text(at: 1, in: statement) ?? "",
                sourceType: InventorySourceType(rawValue: database.text(at: 2, in: statement) ?? "") ?? .unknown,
                serialNumber: database.text(at: 3, in: statement),
                username: database.text(at: 4, in: statement),
                displayName: database.text(at: 5, in: statement),
                assetTag: database.text(at: 6, in: statement),
                phoneNumber: database.text(at: 7, in: statement),
                osVersion: database.text(at: 8, in: statement),
                model: database.text(at: 9, in: statement),
                rawJSON: database.text(at: 10, in: statement) ?? "{}"
            )
            results.append(record)
        }

        return results
    }

    /// Correlates records by serial and/or username and returns a confidence score.
    public func linkedContext(serialNumber: String?, username: String?) throws -> LinkedDeviceContext {
        let normalizedSerial = serialNumber?.replacingOccurrences(of: " ", with: "").uppercased()
        let usernameTerm = username?.trimmingCharacters(in: .whitespacesAndNewlines)

        let sql = """
        SELECT id, source, source_type, serial_number, username, display_name, asset_tag, phone_number, os_version, model, raw_json
        FROM inventory_records
        WHERE
            (? IS NOT NULL AND serial_number = ?) OR
            (? IS NOT NULL AND username LIKE ?)
        LIMIT 20;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        try database.bind(normalizedSerial, at: 1, in: statement)
        try database.bind(normalizedSerial, at: 2, in: statement)
        try database.bind(usernameTerm, at: 3, in: statement)
        try database.bind(usernameTerm.map { "%\($0)%" }, at: 4, in: statement)

        var records: [DeviceRecord] = []
        while try database.step(statement) == SQLITE_ROW {
            records.append(
                DeviceRecord(
                    id: database.int64(at: 0, in: statement),
                    source: database.text(at: 1, in: statement) ?? "",
                    sourceType: InventorySourceType(rawValue: database.text(at: 2, in: statement) ?? "") ?? .unknown,
                    serialNumber: database.text(at: 3, in: statement),
                    username: database.text(at: 4, in: statement),
                    displayName: database.text(at: 5, in: statement),
                    assetTag: database.text(at: 6, in: statement),
                    phoneNumber: database.text(at: 7, in: statement),
                    osVersion: database.text(at: 8, in: statement),
                    model: database.text(at: 9, in: statement),
                    rawJSON: database.text(at: 10, in: statement) ?? "{}"
                )
            )
        }

        let confidence: Double
        if let normalizedSerial, records.contains(where: { $0.serialNumber == normalizedSerial }) {
            confidence = 1.0
        } else if let usernameTerm, records.contains(where: { ($0.username ?? "").localizedCaseInsensitiveContains(usernameTerm) }) {
            confidence = 0.8
        } else {
            confidence = records.isEmpty ? 0 : 0.45
        }

        return LinkedDeviceContext(records: records, confidence: confidence)
    }

    /// Maps the lookup field enum to SQL routing tokens used in a shared query.
    private func fieldToken(for field: LookupField) -> String {
        switch field {
        case .serialNumber:
            return "serial"
        case .displayName:
            return "display"
        case .username:
            return "username"
        case .assetTag:
            return "asset"
        case .phoneNumber:
            return "phone"
        case .any:
            return "any"
        }
    }
}

/// SQLite-backed repository for tracked ticket triage records and resolution history.
public final class SQLiteTicketHistoryRepository: TicketHistoryRepository {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    /// Creates or updates one tracked ticket record.
    public func upsert(
        ticketNumber: String,
        sourceText: String,
        responseTemplate: String,
        resolutionSummary: String?,
        missingFields: [String]
    ) throws {
        let now = Date().timeIntervalSince1970
        let statement = try database.prepare(
            """
            INSERT INTO triage_tickets (
                ticket_number,
                source_text,
                response_template,
                resolution_summary,
                missing_fields_json,
                created_at,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(ticket_number) DO UPDATE SET
                source_text = excluded.source_text,
                response_template = excluded.response_template,
                resolution_summary = COALESCE(excluded.resolution_summary, triage_tickets.resolution_summary),
                missing_fields_json = excluded.missing_fields_json,
                updated_at = excluded.updated_at;
            """
        )
        defer { database.finalize(statement) }

        try database.bind(ticketNumber, at: 1, in: statement)
        try database.bind(sourceText, at: 2, in: statement)
        try database.bind(responseTemplate, at: 3, in: statement)
        try database.bind(resolutionSummary, at: 4, in: statement)
        try database.bind(Self.encodeArray(missingFields), at: 5, in: statement)
        try database.bind(now, at: 6, in: statement)
        try database.bind(now, at: 7, in: statement)
        _ = try database.step(statement)
    }

    /// Returns recent ticket records sorted by last update time.
    public func listRecent(limit: Int) throws -> [TriageTicketRecord] {
        let statement = try database.prepare(
            """
            SELECT id, ticket_number, source_text, response_template, resolution_summary, missing_fields_json, created_at, updated_at
            FROM triage_tickets
            ORDER BY updated_at DESC
            LIMIT ?;
            """
        )
        defer { database.finalize(statement) }

        try database.bind(Int64(limit), at: 1, in: statement)

        var records: [TriageTicketRecord] = []
        while try database.step(statement) == SQLITE_ROW {
            records.append(
                TriageTicketRecord(
                    id: database.int64(at: 0, in: statement),
                    ticketNumber: database.text(at: 1, in: statement) ?? "",
                    sourceText: database.text(at: 2, in: statement) ?? "",
                    responseTemplate: database.text(at: 3, in: statement) ?? "",
                    resolutionSummary: database.text(at: 4, in: statement),
                    missingFields: Self.decodeArray(database.text(at: 5, in: statement)),
                    createdAt: Date(timeIntervalSince1970: database.double(at: 6, in: statement)),
                    updatedAt: Date(timeIntervalSince1970: database.double(at: 7, in: statement))
                )
            )
        }

        return records
    }

    private static func encodeArray(_ values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func decodeArray(_ raw: String?) -> [String] {
        guard
            let raw,
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return decoded
    }
}

/// SQLite-backed repository for user-defined triage response templates.
public final class SQLiteResponseTemplateRepository: ResponseTemplateRepository {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    /// Returns saved templates ordered by recently updated.
    public func listTemplates(limit: Int) throws -> [SavedResponseTemplate] {
        let statement = try database.prepare(
            """
            SELECT id, name, body, created_at, updated_at
            FROM response_templates
            ORDER BY updated_at DESC
            LIMIT ?;
            """
        )
        defer { database.finalize(statement) }

        try database.bind(Int64(limit), at: 1, in: statement)

        var templates: [SavedResponseTemplate] = []
        while try database.step(statement) == SQLITE_ROW {
            templates.append(
                SavedResponseTemplate(
                    id: database.int64(at: 0, in: statement),
                    name: database.text(at: 1, in: statement) ?? "",
                    body: database.text(at: 2, in: statement) ?? "",
                    createdAt: Date(timeIntervalSince1970: database.double(at: 3, in: statement)),
                    updatedAt: Date(timeIntervalSince1970: database.double(at: 4, in: statement))
                )
            )
        }

        return templates
    }

    /// Saves or updates one template keyed by name.
    @discardableResult
    public func saveTemplate(name: String, body: String) throws -> SavedResponseTemplate {
        let now = Date().timeIntervalSince1970
        let upsert = try database.prepare(
            """
            INSERT INTO response_templates(name, body, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(name) DO UPDATE SET
                body = excluded.body,
                updated_at = excluded.updated_at;
            """
        )
        defer { database.finalize(upsert) }

        try database.bind(name, at: 1, in: upsert)
        try database.bind(body, at: 2, in: upsert)
        try database.bind(now, at: 3, in: upsert)
        try database.bind(now, at: 4, in: upsert)
        _ = try database.step(upsert)

        let query = try database.prepare(
            """
            SELECT id, name, body, created_at, updated_at
            FROM response_templates
            WHERE name = ?
            LIMIT 1;
            """
        )
        defer { database.finalize(query) }

        try database.bind(name, at: 1, in: query)
        guard try database.step(query) == SQLITE_ROW else {
            throw SQLiteError.stepFailed("Template lookup failed after save")
        }

        return SavedResponseTemplate(
            id: database.int64(at: 0, in: query),
            name: database.text(at: 1, in: query) ?? name,
            body: database.text(at: 2, in: query) ?? body,
            createdAt: Date(timeIntervalSince1970: database.double(at: 3, in: query)),
            updatedAt: Date(timeIntervalSince1970: database.double(at: 4, in: query))
        )
    }

    /// Deletes a stored response template by identifier.
    public func deleteTemplate(id: Int64) throws {
        let statement = try database.prepare("DELETE FROM response_templates WHERE id = ?;")
        defer { database.finalize(statement) }
        try database.bind(id, at: 1, in: statement)
        _ = try database.step(statement)
    }
}
