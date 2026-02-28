import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import TicketCrusherCore
import TicketCrusherFeatures
import TicketCrusherStorage

/// Main presentation model that coordinates UI state with storage and feature services.
/// Developed by Jim Daley.
@MainActor
final class AppViewModel: ObservableObject {
    private static let datasetDirectoryName = "datasets"
    private static let datasetManifestFileName = "dataset_manifest.json"

    private static let supportedImportExtensions: Set<String> = [
        "jsonl", "json", "csv", "txt", "md", "markdown", "pdf", "docx", "doxs", "doc", "rtf", "xlsx", "xls", "log", "zip"
    ]

    private static let supportedImportContentTypes: [UTType] = supportedImportExtensions.compactMap {
        UTType(filenameExtension: $0)
    }

    private static let empathyRotationIndexKey = "ticketCrusher.empathyRotationIndex"
    private static let empathyOpeners: [String] = [
        "I'm sorry you're experiencing this issue.",
        "I'm sorry this has been frustrating, and I appreciate your patience.",
        "I'm sorry you ran into this problem, and I want to help get this resolved quickly.",
        "I'm sorry this issue interrupted your work. Let's get it fixed as fast as possible.",
        "I'm sorry this happened, and I know how disruptive it can be.",
        "I'm sorry for the trouble you're dealing with. I'm here to help.",
        "I'm sorry you're impacted by this issue, and thank you for reporting it."
    ]

    // MARK: Chat and Triage State

    @Published var messages: [ChatMessage] = []
    @Published var chatInput: String = ""

    @Published var triageTicketNumber: String = ""
    @Published var triageTicketText: String = ""
    @Published var triageResponseTemplate: String = ""
    @Published var triageResolutionSummary: String = ""
    @Published var triageMissingItems: [String] = []

    @Published var templateNameDraft: String = ""
    @Published var templateBodyDraft: String = ""
    @Published var savedTemplates: [SavedResponseTemplate] = []
    @Published var selectedTemplateID: Int64?

    @Published var recentTrackedTickets: [TriageTicketRecord] = []

    // MARK: KB State

    @Published var kbSearchText: String = ""
    @Published var kbResults: [KBSearchResult] = []
    @Published var selectedKBArticle: KBArticle?

    // MARK: Inventory State

    @Published var assetSearchText: String = ""
    @Published var assetResults: [DeviceRecord] = []

    // MARK: App State

    @Published var dataPackRootPath: String
    @Published var statusText: String = "Ready"
    @Published var exportText: String = ""
    @Published var diagnosticLogs: [DiagnosticLogEntry] = []
    @Published var selectedDiagnosticLogID: Int64?
    @Published var selectedDiagnosticLog: DiagnosticLogEntry?

    private let storage: StorageContainer?
    private let ticketHistoryRepository: TicketHistoryRepository?
    private let responseTemplateRepository: ResponseTemplateRepository?
    private let diagnosticsRepository: DiagnosticsRepository?
    private let logger: SupportLogger?
    private var orchestrator: ConversationOrchestrator?
    private var retrievalService: KnowledgeRetrievalService?
    private let exportService = TicketExportService()
    private var empathyOpenerByTicket: [String: String] = [:]

    /// Initializes storage-backed services and sets the default datasets folder path.
    init() {
        let defaultRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(Self.datasetDirectoryName)
        self.dataPackRootPath = defaultRoot.path

        do {
            let storage = try StorageContainer()
            self.storage = storage
            self.ticketHistoryRepository = storage.ticketHistoryRepository
            self.responseTemplateRepository = storage.responseTemplateRepository
            self.diagnosticsRepository = storage.diagnosticsRepository
            self.logger = storage.logger
            self.statusText = "Database ready: \(storage.database.databasePath)"
            self.orchestrator = ConversationOrchestrator(
                kbRepository: storage.kbRepository,
                inventoryRepository: storage.inventoryRepository,
                policy: .default()
            )
            self.retrievalService = KnowledgeRetrievalService(kbRepository: storage.kbRepository)
            loadSavedTemplates()
            loadRecentTrackedTickets()
            logger?.log("Ticket Crusher initialized.")
            loadDiagnosticLogs()
        } catch {
            self.storage = nil
            self.ticketHistoryRepository = nil
            self.responseTemplateRepository = nil
            self.diagnosticsRepository = nil
            self.logger = nil
            self.statusText = "Failed to initialize storage: \(error.localizedDescription)"
        }
    }

    // MARK: Data Ingestion Pipeline

    /// Imports supported files from the configured dataset root and refreshes runtime services.
    func importData() {
        do {
            let selected = URL(fileURLWithPath: dataPackRootPath, isDirectory: true)
            let root = try prepareDatasetRoot(from: selected)
            importData(from: root)
        } catch {
            handleError(
                error,
                context: "ingestion.prepareDatasetRoot",
                userMessage: "Unable to prepare dataset directory"
            )
        }
    }

    /// Opens Finder so the user can choose a dataset root directory.
    func chooseDatasetFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Dataset Folder"
        panel.message = "Select the folder that contains your support datasets."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        do {
            let preparedRoot = try prepareDatasetRoot(from: selectedURL)
            statusText = "Selected dataset folder: \(preparedRoot.path)"
        } catch {
            handleError(
                error,
                context: "ingestion.chooseDatasetFolder",
                userMessage: "Failed to prepare dataset folder"
            )
        }
    }

    /// Opens Finder and ingests selected files/directories into the configured dataset root.
    func importFromFinder() {
        let panel = NSOpenPanel()
        panel.title = "Import Dataset Files"
        panel.message = "Select files, folders, or .zip archives to ingest into Ticket Crusher."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.allowedContentTypes = Self.supportedImportContentTypes
        panel.allowsOtherFileTypes = false

        guard panel.runModal() == .OK else {
            return
        }

        let selectedItems = panel.urls
        guard !selectedItems.isEmpty else {
            return
        }

        do {
            let selectedRoot = URL(fileURLWithPath: dataPackRootPath, isDirectory: true)
            let root = try prepareDatasetRoot(from: selectedRoot)
            let copiedCount = try copySupportedImportItems(selectedItems, into: root)
            // If no new files were copied, still allow a refresh against files already in the dataset root.
            if copiedCount == 0 {
                let existingCount = try countSupportedFiles(in: root)
                guard existingCount > 0 else {
                    statusText = "No supported files were selected. Use formats like .csv, .json, .md, .txt, .pdf, or .docx."
                    return
                }

                importData(from: root, statusPrefix: "Using \(existingCount) existing dataset file(s). ")
                return
            }
            importData(from: root, statusPrefix: "Ingestion pipeline added \(copiedCount) file(s). ")
        } catch {
            handleError(
                error,
                context: "ingestion.importFromFinder",
                userMessage: "Finder import failed"
            )
        }
    }

    /// Imports all supported files from the provided root and refreshes runtime services.
    private func importData(from root: URL, statusPrefix: String = "") {
        guard let storage else {
            statusText = "Storage unavailable"
            return
        }

        statusText = "Running ingestion pipeline..."

        let preparedRoot: URL
        do {
            preparedRoot = try prepareDatasetRoot(from: root)
        } catch {
            handleError(
                error,
                context: "ingestion.prepareDatasetRoot",
                userMessage: "Unable to prepare dataset directory"
            )
            return
        }

        let config = DataPackConfiguration(
            rootDirectory: preparedRoot,
            knowledgeBasePath: preparedRoot.appendingPathComponent("kb_corpus.jsonl"),
            managedMacsPath: preparedRoot.appendingPathComponent("managed_macs.jsonl"),
            managedMobilePath: preparedRoot.appendingPathComponent("managed_mobile_devices.jsonl"),
            assetsPath: preparedRoot.appendingPathComponent("assets.jsonl"),
            appleIntakePath: preparedRoot.appendingPathComponent("apple_intake_filtered.jsonl"),
            workflowPolicyPath: preparedRoot.appendingPathComponent("cw-support-instructions.json")
        )

        do {
            let report = try storage.importer.importAll(from: config)
            let policy = loadWorkflowPolicy(from: config)

            // Rebuild orchestrator/retrieval services so newly imported data is immediately searchable.
            orchestrator = ConversationOrchestrator(
                kbRepository: storage.kbRepository,
                inventoryRepository: storage.inventoryRepository,
                policy: policy
            )
            retrievalService = KnowledgeRetrievalService(kbRepository: storage.kbRepository)

            if report.importedFiles.isEmpty,
               report.skippedFiles.contains(where: { $0.hasPrefix("No supported dataset files found in ") }) {
                statusText = "\(statusPrefix)Dataset directory is ready at \(preparedRoot.path). Use Import Files... to add data."
                return
            }

            let imported = report.importedFiles.joined(separator: ", ")
            let skipped = report.skippedFiles.joined(separator: ", ")
            statusText = "\(statusPrefix)Ingestion complete. Imported: [\(imported)] Skipped: [\(skipped)]"
            logger?.log("Ingestion completed for \(preparedRoot.lastPathComponent)")
        } catch {
            handleError(
                error,
                context: "ingestion.importData",
                userMessage: "Import failed"
            )
        }
    }

    /// Copies supported selected files (or files within selected folders) into dataset root.
    private func copySupportedImportItems(_ items: [URL], into destinationRoot: URL) throws -> Int {
        var copiedCount = 0
        for item in items {
            copiedCount += try copySupportedImportItem(item, into: destinationRoot)
        }
        return copiedCount
    }

    /// Copies one selected file/folder into dataset root while preserving directory-relative layout.
    private func copySupportedImportItem(_ item: URL, into destinationRoot: URL) throws -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) else {
            return 0
        }

        if isDirectory.boolValue {
            if item.standardizedFileURL.path == destinationRoot.standardizedFileURL.path {
                return 0
            }

            var copied = 0
            let enumerator = FileManager.default.enumerator(
                at: item,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            while let child = enumerator?.nextObject() as? URL {
                var childDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child.path, isDirectory: &childDirectory),
                      !childDirectory.boolValue else {
                    continue
                }

                let ext = child.pathExtension.lowercased()
                guard Self.supportedImportExtensions.contains(ext) else {
                    continue
                }

                let relativePath = child.path.replacingOccurrences(of: item.path + "/", with: "")
                let destination = destinationRoot
                    .appendingPathComponent(item.lastPathComponent, isDirectory: true)
                    .appendingPathComponent(relativePath)

                try copyFileReplacingIfNeeded(from: child, to: destination)
                copied += 1
            }

            return copied
        }

        let ext = item.pathExtension.lowercased()
        if ext == "zip" {
            return try extractZipArchive(item, into: destinationRoot)
        }

        guard Self.supportedImportExtensions.contains(ext) else {
            return 0
        }

        let destination = destinationRoot.appendingPathComponent(item.lastPathComponent)
        try copyFileReplacingIfNeeded(from: item, to: destination)
        return 1
    }

    /// Replaces destination file when needed, preserving latest selected source content.
    private func copyFileReplacingIfNeeded(from source: URL, to destination: URL) throws {
        if source.standardizedFileURL.path == destination.standardizedFileURL.path {
            return
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Extracts a .zip archive into dataset root and returns count of supported extracted files.
    private func extractZipArchive(_ archiveURL: URL, into destinationRoot: URL) throws -> Int {
        let extractionDirectory = destinationRoot
            .appendingPathComponent(archiveURL.deletingPathExtension().lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, extractionDirectory.path]

        let stdErr = Pipe()
        process.standardError = stdErr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stdErr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Unknown archive extraction error."
            throw NSError(
                domain: "TicketCrusherIngestion",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to extract zip archive: \(message)"]
            )
        }

        return try countSupportedFiles(in: extractionDirectory)
    }

    /// Counts supported files recursively in a directory for ingestion progress/status reporting.
    private func countSupportedFiles(in root: URL) throws -> Int {
        var count = 0
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let next = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: next.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            let ext = next.pathExtension.lowercased()
            if Self.supportedImportExtensions.contains(ext), ext != "zip" {
                count += 1
            }
        }

        return count
    }

    /// Selects and prepares the dataset root directory, creating it when needed.
    private func prepareDatasetRoot(from selectedURL: URL) throws -> URL {
        let resolved = resolveDatasetRoot(from: selectedURL)
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        try ensureDatasetManifest(in: resolved)
        dataPackRootPath = resolved.path
        return resolved
    }

    /// Resolves whether to use the selected folder directly or its nested `datasets` directory.
    private func resolveDatasetRoot(from selectedURL: URL) -> URL {
        let standardized = selectedURL.standardizedFileURL
        if standardized.lastPathComponent.lowercased() == Self.datasetDirectoryName {
            return standardized
        }

        if containsSupportedFiles(in: standardized) {
            return standardized
        }

        let nested = standardized.appendingPathComponent(Self.datasetDirectoryName, isDirectory: true)
        if containsSupportedFiles(in: nested) {
            return nested
        }

        return nested
    }

    /// Checks whether a directory contains at least one supported import file.
    private func containsSupportedFiles(in directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let next = enumerator?.nextObject() as? URL {
            var childIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: next.path, isDirectory: &childIsDirectory), !childIsDirectory.boolValue else {
                continue
            }

            if Self.supportedImportExtensions.contains(next.pathExtension.lowercased()) {
                return true
            }
        }

        return false
    }

    /// Ensures the dataset manifest file exists so the dataset root is self-describing.
    private func ensureDatasetManifest(in root: URL) throws {
        let manifestURL = root.appendingPathComponent(Self.datasetManifestFileName)
        guard !FileManager.default.fileExists(atPath: manifestURL.path) else {
            return
        }

        let payload: [String: Any] = [
            "name": "Ticket Crusher Dataset",
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "root_path": root.path,
            "supported_extensions": Array(Self.supportedImportExtensions).sorted()
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: [.atomic])
    }

    /// Loads workflow policy from the configured file or auto-discovers a matching policy file.
    private func loadWorkflowPolicy(from config: DataPackConfiguration) -> SupportWorkflowPolicy {
        if FileManager.default.fileExists(atPath: config.workflowPolicyPath.path),
           let policy = try? SupportWorkflowPolicy.load(from: config.workflowPolicyPath) {
            return policy
        }

        if let discoveredPolicyURL = discoverWorkflowPolicy(in: config.rootDirectory),
           let policy = try? SupportWorkflowPolicy.load(from: discoveredPolicyURL) {
            return policy
        }

        return .default()
    }

    /// Finds a JSON instruction file when a direct policy path is missing.
    private func discoverWorkflowPolicy(in root: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let next = enumerator?.nextObject() as? URL {
            let lower = next.lastPathComponent.lowercased()
            if lower.hasSuffix(".json") && lower.contains("support") && lower.contains("instruction") {
                return next
            }
        }

        return nil
    }

    // MARK: Diagnostics

    /// Refreshes diagnostics records shown in the Settings diagnostics view.
    func refreshDiagnostics() {
        loadDiagnosticLogs()
    }

    /// Selects one diagnostics entry and loads the full details for display.
    func selectDiagnosticLog(_ logID: Int64?) {
        selectedDiagnosticLogID = logID
        guard let logID else {
            selectedDiagnosticLog = nil
            return
        }

        guard let repository = diagnosticsRepository else {
            selectedDiagnosticLog = nil
            return
        }

        do {
            selectedDiagnosticLog = try repository.get(id: logID)
        } catch {
            selectedDiagnosticLog = nil
            handleError(
                error,
                context: "diagnostics.select",
                userMessage: "Failed to open selected log"
            )
        }
    }

    /// Exports diagnostics logs as plain text so support can attach them to tickets.
    func exportDiagnosticsAsText() {
        guard let repository = diagnosticsRepository else {
            statusText = "Diagnostics storage unavailable"
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Diagnostic Logs"
        panel.message = "Save diagnostic logs as a .txt file."
        panel.nameFieldStringValue = "ticket-crusher-diagnostics-\(timestampForFilename()).txt"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]

        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        do {
            let text = try repository.exportText(limit: 10_000)
            try text.write(to: destination, atomically: true, encoding: .utf8)
            statusText = "Diagnostics exported to \(destination.path)"
            logger?.log("Diagnostics export saved to \(destination.path)")
        } catch {
            handleError(
                error,
                context: "diagnostics.export",
                userMessage: "Failed to export diagnostics"
            )
        }
    }

    // MARK: Ticket Triage

    /// Runs deterministic triage using ticket number + pasted SD+ ticket details.
    func crushTicket() {
        guard let orchestrator else {
            statusText = "The support engine is not initialized. Import data from Settings first."
            return
        }

        let ticketBody = triageTicketText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ticketBody.isEmpty else {
            statusText = "Paste the SD+ ticket details before pressing Crush It."
            return
        }

        let normalizedTicket = normalizeTicketNumber(triageTicketNumber)
        guard !normalizedTicket.isEmpty else {
            statusText = "Enter a ticket number before pressing Crush It."
            return
        }

        triageTicketNumber = normalizedTicket

        let triageInput = composeTriageMessage(ticketNumber: normalizedTicket, body: ticketBody)

        do {
            let turn = try orchestrator.handle(message: triageInput)
            let location = extractLocation(from: ticketBody)
            let otherUsers = extractOtherUsers(from: ticketBody)
            let issueScope = extractIssueScope(from: ticketBody, intake: turn.intake)
            // Compute missing data after extraction so the output template can request precise follow-up details.
            let missing = detectMissingTriageData(turn: turn, sourceText: ticketBody, location: location, otherUsers: otherUsers, issueScope: issueScope)

            triageMissingItems = missing

            // Prefer a saved custom template when selected; otherwise fall back to the built-in response template.
            if let selected = selectedTemplate() {
                triageResponseTemplate = render(
                    savedTemplate: selected,
                    turn: turn,
                    ticketNumber: normalizedTicket,
                    location: location,
                    otherUsers: otherUsers,
                    issueScope: issueScope,
                    missingItems: missing
                )
            } else {
                triageResponseTemplate = buildDefaultTriageTemplate(
                    turn: turn,
                    ticketNumber: normalizedTicket,
                    location: location,
                    otherUsers: otherUsers,
                    issueScope: issueScope,
                    missingItems: missing
                )
            }

            // Build a customer-facing follow-up message and include it in the export package.
            let endUserScript = buildEndUserFollowUpScript(
                ticketNumber: normalizedTicket,
                issueDescription: turn.intake.issueDescription,
                missingItems: missing
            )
            exportText = composeExportPackage(
                endUserScript: endUserScript,
                technicianTemplate: triageResponseTemplate
            )
            messages.append(ChatMessage(role: .user, text: triageInput))
            messages.append(ChatMessage(role: .assistant, text: triageResponseTemplate, citations: turn.response.citations))

            try persistTrackedTicket(
                ticketNumber: normalizedTicket,
                sourceText: ticketBody,
                responseTemplate: triageResponseTemplate,
                resolutionSummary: normalizedOptional(triageResolutionSummary),
                missingItems: missing
            )

            statusText = missing.isEmpty
                ? "Ticket \(normalizedTicket) triaged and tracked."
                : "Ticket \(normalizedTicket) triaged. Missing: \(missing.joined(separator: ", "))."
            logger?.log("Ticket \(normalizedTicket) triaged")
        } catch {
            handleError(
                error,
                context: "triage.crushTicket",
                userMessage: "Triage failed"
            )
        }
    }

    /// Persists or updates a ticket resolution for the current ticket.
    func saveTriageResolution() {
        let ticketNumber = normalizeTicketNumber(triageTicketNumber)
        guard !ticketNumber.isEmpty else {
            statusText = "Enter a ticket number before saving a resolution."
            return
        }

        let sourceText = triageTicketText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else {
            statusText = "No ticket text is loaded for this ticket."
            return
        }

        let responseTemplate = triageResponseTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !responseTemplate.isEmpty else {
            statusText = "Run triage first so there is a response template to track."
            return
        }

        do {
            try persistTrackedTicket(
                ticketNumber: ticketNumber,
                sourceText: sourceText,
                responseTemplate: responseTemplate,
                resolutionSummary: normalizedOptional(triageResolutionSummary),
                missingItems: triageMissingItems
            )
            statusText = "Resolution saved for ticket \(ticketNumber)."
            logger?.log("Resolution saved for ticket \(ticketNumber)")
        } catch {
            handleError(
                error,
                context: "triage.saveResolution",
                userMessage: "Failed to save resolution"
            )
        }
    }

    /// Copies the generated SD+ triage response template to the macOS pasteboard.
    func copyTriageTemplate() {
        let text = triageResponseTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusText = "No triage template is available to copy yet."
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusText = "Triage response template copied"
    }

    /// Saves or updates a user-defined triage response template.
    func saveResponseTemplateDraft() {
        guard let repository = responseTemplateRepository else {
            statusText = "Template storage unavailable"
            return
        }

        let name = templateNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = templateBodyDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            statusText = "Template name is required"
            return
        }

        guard !body.isEmpty else {
            statusText = "Template body is required"
            return
        }

        do {
            let saved = try repository.saveTemplate(name: name, body: body)
            selectedTemplateID = saved.id
            loadSavedTemplates()
            statusText = "Template '\(name)' saved"
            logger?.log("Saved response template '\(name)'")
        } catch {
            handleError(
                error,
                context: "triage.saveTemplate",
                userMessage: "Failed to save template"
            )
        }
    }

    /// Deletes the currently selected user-defined triage response template.
    func deleteSelectedTemplate() {
        guard let repository = responseTemplateRepository else {
            statusText = "Template storage unavailable"
            return
        }

        guard let selectedTemplateID else {
            statusText = "Select a template first"
            return
        }

        do {
            let deletedID = selectedTemplateID
            try repository.deleteTemplate(id: selectedTemplateID)
            self.selectedTemplateID = nil
            loadSavedTemplates()
            statusText = "Template deleted"
            logger?.log("Deleted response template id \(deletedID)")
        } catch {
            handleError(
                error,
                context: "triage.deleteTemplate",
                userMessage: "Failed to delete template"
            )
        }
    }

    /// Loads a tracked ticket into the triage editor for follow-up updates.
    func loadTrackedTicket(_ record: TriageTicketRecord) {
        triageTicketNumber = record.ticketNumber
        triageTicketText = record.sourceText
        triageResponseTemplate = record.responseTemplate
        triageResolutionSummary = record.resolutionSummary ?? ""
        triageMissingItems = record.missingFields
        statusText = "Loaded ticket \(record.ticketNumber)"
    }

    /// Loads a template into the template editor and marks it as active for Crush It.
    func loadResponseTemplate(_ template: SavedResponseTemplate) {
        selectedTemplateID = template.id
        templateNameDraft = template.name
        templateBodyDraft = template.body
        statusText = "Loaded template '\(template.name)'"
    }

    // MARK: KB and Inventory

    /// Sends the user's message through the orchestrator and updates transcript/export state.
    func sendMessage() {
        let message = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        messages.append(ChatMessage(role: .user, text: message))
        chatInput = ""

        guard let orchestrator else {
            let text = "The support engine is not initialized. Import data from Settings first."
            messages.append(ChatMessage(role: .assistant, text: text))
            return
        }

        do {
            let turn = try orchestrator.handle(message: message)
            messages.append(ChatMessage(role: .assistant, text: turn.text, citations: turn.response.citations))
            exportText = exportService.exportSummary(intake: turn.intake, response: turn.response)
            statusText = "Conversation updated"
        } catch {
            messages.append(ChatMessage(role: .assistant, text: "Error: \(error.localizedDescription)"))
            handleError(
                error,
                context: "chat.sendMessage",
                userMessage: "Chat error"
            )
        }
    }

    /// Runs a KB query and selects the highest-ranked article when results are available.
    func searchKB() {
        let query = kbSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            kbResults = []
            selectedKBArticle = nil
            return
        }

        do {
            let service = retrievalService
            guard let service else {
                statusText = "Import data before searching the KB"
                return
            }

            let results = try service.search(query: query, limit: 30)
            kbResults = results
            selectedKBArticle = results.first?.article
            statusText = "Found \(results.count) KB results"
        } catch {
            handleError(
                error,
                context: "kb.search",
                userMessage: "KB search failed"
            )
        }
    }

    /// Performs inventory lookup against local records using a broad multi-field search.
    func lookupAssets() {
        let text = assetSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            assetResults = []
            return
        }

        guard let storage else {
            statusText = "Storage unavailable"
            return
        }

        do {
            assetResults = try storage.inventoryRepository.lookup(
                InventoryLookupQuery(text: text, field: .any),
                limit: 100
            )
            statusText = "Found \(assetResults.count) inventory records"
        } catch {
            handleError(
                error,
                context: "inventory.lookup",
                userMessage: "Lookup failed"
            )
        }
    }

    /// Copies the rendered export text into the macOS pasteboard.
    func copyExport() {
        let text = exportText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusText = "Export copied"
    }

    /// Clears chat and triage state for a new workflow.
    func resetConversation() {
        messages = []
        chatInput = ""
        triageTicketNumber = ""
        triageTicketText = ""
        triageResponseTemplate = ""
        triageResolutionSummary = ""
        triageMissingItems = []
        orchestrator?.resetSession()
        exportText = ""
        statusText = "Conversation reset"
    }

    /// Returns only the most recent transcript subset for quick display on the Home tab.
    var recentConversationPreview: [ChatMessage] {
        Array(messages.suffix(6))
    }

    // MARK: Error Handling and Diagnostics Internals

    /// Loads recent diagnostics entries and keeps the current selection in sync.
    private func loadDiagnosticLogs(silently: Bool = false) {
        guard let repository = diagnosticsRepository else {
            diagnosticLogs = []
            selectedDiagnosticLogID = nil
            selectedDiagnosticLog = nil
            return
        }

        do {
            let logs = try repository.listRecent(limit: 500)
            diagnosticLogs = logs

            if let selectedID = selectedDiagnosticLogID,
               let selected = logs.first(where: { $0.id == selectedID }) {
                selectedDiagnosticLog = selected
            } else if let first = logs.first {
                selectedDiagnosticLogID = first.id
                selectedDiagnosticLog = first
            } else {
                selectedDiagnosticLogID = nil
                selectedDiagnosticLog = nil
            }
        } catch {
            diagnosticLogs = []
            selectedDiagnosticLogID = nil
            selectedDiagnosticLog = nil

            guard !silently else { return }
            handleError(
                error,
                context: "diagnostics.load",
                userMessage: "Failed to load diagnostics logs"
            )
        }
    }

    /// Handles caught errors in one place and writes them into diagnostics.
    private func handleError(_ error: Error, context: String, userMessage: String) {
        statusText = "\(userMessage): \(error.localizedDescription)"
        recordError(error, context: context)
    }

    /// Writes one structured diagnostics error event, including stack and NSError metadata.
    private func recordError(_ error: Error, context: String) {
        let message = error.localizedDescription
        let details = detailedErrorPayload(error: error, context: context)

        if let diagnosticsRepository {
            do {
                try diagnosticsRepository.append(
                    level: .error,
                    category: context,
                    message: message,
                    details: details
                )
                loadDiagnosticLogs(silently: true)
                return
            } catch {
                // Fall back to basic logger if diagnostics write itself fails.
            }
        }

        logger?.error("[\(context)] \(message)")
    }

    /// Builds a detailed error payload useful for post-incident troubleshooting.
    private func detailedErrorPayload(error: Error, context: String) -> String {
        let nsError = error as NSError
        var lines: [String] = []
        lines.append("Context: \(context)")
        lines.append("Error Type: \(String(describing: type(of: error)))")
        lines.append("NSError Domain: \(nsError.domain)")
        lines.append("NSError Code: \(nsError.code)")

        if !nsError.userInfo.isEmpty {
            lines.append("User Info: \(nsError.userInfo)")
        }

        let stack = Thread.callStackSymbols.prefix(12).joined(separator: "\n")
        if !stack.isEmpty {
            lines.append("Call Stack:")
            lines.append(stack)
        }

        return lines.joined(separator: "\n")
    }

    /// Builds a filesystem-safe timestamp used in diagnostics export filenames.
    private func timestampForFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: End-User Messaging

    /// Combines the customer-facing follow-up script with the technician response template for export.
    private func composeExportPackage(endUserScript: String, technicianTemplate: String) -> String {
        var sections: [String] = []
        sections.append("End-User Follow-Up")
        sections.append(endUserScript)
        sections.append("")
        sections.append("Technician Template")
        sections.append(technicianTemplate)
        return sections.joined(separator: "\n")
    }

    /// Builds a polite customer follow-up script that requests missing intake details.
    private func buildEndUserFollowUpScript(
        ticketNumber: String,
        issueDescription: String?,
        missingItems: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("Hi,")
        lines.append("")
        lines.append(empathyOpener(for: ticketNumber))

        if let issueDescription = normalizedOptional(issueDescription) {
            lines.append("I reviewed ticket \(ticketNumber) regarding: \(issueDescription).")
        } else {
            lines.append("I reviewed ticket \(ticketNumber) and want to move this forward quickly.")
        }

        if missingItems.isEmpty {
            lines.append("At this time, I have the required intake details to continue troubleshooting.")
            lines.append("If you can share any recent changes before the issue started, that can still help speed up resolution.")
        } else {
            lines.append("To continue, could you please provide the details below:")
            for item in missingItems {
                lines.append("- \(item)")
            }
        }

        lines.append("")
        lines.append("Thank you for your help. Once I have this information, I will continue troubleshooting right away.")

        return lines.joined(separator: "\n")
    }

    /// Returns a stable empathy opener for each ticket while rotating openers across new tickets.
    private func empathyOpener(for ticketNumber: String) -> String {
        if let existing = empathyOpenerByTicket[ticketNumber] {
            return existing
        }

        let index = UserDefaults.standard.integer(forKey: Self.empathyRotationIndexKey)
        let phrase = Self.empathyOpeners[index % Self.empathyOpeners.count]
        let nextIndex = (index + 1) % Self.empathyOpeners.count
        UserDefaults.standard.set(nextIndex, forKey: Self.empathyRotationIndexKey)
        empathyOpenerByTicket[ticketNumber] = phrase
        return phrase
    }

    // MARK: Triage Internals

    /// Saves ticket tracking data and refreshes recent ticket history.
    private func persistTrackedTicket(
        ticketNumber: String,
        sourceText: String,
        responseTemplate: String,
        resolutionSummary: String?,
        missingItems: [String]
    ) throws {
        guard let repository = ticketHistoryRepository else {
            return
        }

        try repository.upsert(
            ticketNumber: ticketNumber,
            sourceText: sourceText,
            responseTemplate: responseTemplate,
            resolutionSummary: resolutionSummary,
            missingFields: missingItems
        )

        loadRecentTrackedTickets()
    }

    /// Refreshes saved custom templates from SQLite.
    private func loadSavedTemplates() {
        guard let repository = responseTemplateRepository else {
            savedTemplates = []
            return
        }

        do {
            savedTemplates = try repository.listTemplates(limit: 100)
        } catch {
            savedTemplates = []
            handleError(
                error,
                context: "triage.loadTemplates",
                userMessage: "Failed to load templates"
            )
        }
    }

    /// Refreshes recent tracked tickets from SQLite.
    private func loadRecentTrackedTickets() {
        guard let repository = ticketHistoryRepository else {
            recentTrackedTickets = []
            return
        }

        do {
            recentTrackedTickets = try repository.listRecent(limit: 100)
        } catch {
            recentTrackedTickets = []
            handleError(
                error,
                context: "triage.loadTrackedTickets",
                userMessage: "Failed to load tracked tickets"
            )
        }
    }

    /// Returns the currently selected custom response template if any.
    private func selectedTemplate() -> SavedResponseTemplate? {
        guard let selectedTemplateID else { return nil }
        return savedTemplates.first(where: { $0.id == selectedTemplateID })
    }

    /// Builds the standardized triage input expected by the ticket workflow parser.
    private func composeTriageMessage(ticketNumber: String, body: String) -> String {
        "##\(ticketNumber)\n\(body)"
    }

    /// Normalizes ticket number formatting for consistent tracking keys.
    private func normalizeTicketNumber(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    /// Returns normalized optional string value when non-empty.
    private func normalizedOptional(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Detects required triage fields that are still missing from the ticket payload.
    private func detectMissingTriageData(
        turn: AssistantTurn,
        sourceText: String,
        location: String?,
        otherUsers: String?,
        issueScope: String?
    ) -> [String] {
        var missing: [String] = []

        if turn.intake.normalizedSerial == nil {
            missing.append("Serial Number")
        }

        if normalizedOptional(turn.intake.wifiSSID) == nil {
            missing.append("Wi-Fi Network In Use")
        }

        if normalizedOptional(location) == nil {
            missing.append("Location")
        }

        if normalizedOptional(otherUsers) == nil {
            missing.append("Is this happening to other users?")
        }

        if normalizedOptional(issueScope) == nil {
            missing.append("Is this an application issue or device issue?")
        }

        // Include any existing workflow prompts as user-facing missing requirements.
        for prompt in turn.response.neededInfo {
            if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missing.append(prompt)
            }
        }

        var seen: Set<String> = []
        return missing.filter { seen.insert($0).inserted }
    }

    /// Extracts location hints from key-value styled ticket text.
    private func extractLocation(from sourceText: String) -> String? {
        extractKeyedValue(
            from: sourceText,
            keys: ["location", "site", "store", "office", "building"]
        )
    }

    /// Extracts whether the issue impacts additional users.
    private func extractOtherUsers(from sourceText: String) -> String? {
        if let value = extractKeyedValue(
            from: sourceText,
            keys: ["other users", "is this happening to other users", "multiple users", "affecting others"]
        ) {
            let lower = value.lowercased()
            if lower.contains("yes") || lower.contains("y") || lower.contains("true") {
                return "Yes"
            }
            if lower.contains("no") || lower.contains("n") || lower.contains("false") {
                return "No"
            }
            return value
        }

        return nil
    }

    /// Extracts issue scope hint (application vs device) from ticket text.
    private func extractIssueScope(from sourceText: String, intake: TicketIntake) -> String? {
        if let value = extractKeyedValue(
            from: sourceText,
            keys: ["issue scope", "scope", "problem type", "application or device"]
        ) {
            return normalizeIssueScope(value)
        }

        let lower = sourceText.lowercased()
        if lower.contains("application issue") || lower.contains("app issue") || lower.contains("problem with the app") {
            return "Application"
        }
        if lower.contains("device issue") || lower.contains("hardware issue") || lower.contains("problem with the device") {
            return "Device"
        }

        if let app = normalizedOptional(intake.appInUseAtIssueTime), !app.isEmpty,
           lower.contains("\(app.lowercased())") && lower.contains("app") {
            return "Application"
        }

        return nil
    }

    /// Returns one value for the first matching `key: value` line in ticket text.
    private func extractKeyedValue(from sourceText: String, keys: [String]) -> String? {
        let loweredKeys = keys.map { $0.lowercased() }

        for rawLine in sourceText.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            line = line.replacingOccurrences(of: "^[-*]\\s*", with: "", options: .regularExpression)
            guard !line.isEmpty else { continue }

            let lower = line.lowercased()
            for key in loweredKeys {
                let prefix = key + ":"
                if lower.hasPrefix(prefix) {
                    let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : value
                }
            }
        }

        return nil
    }

    /// Normalizes free-form scope values to `Application` or `Device` when possible.
    private func normalizeIssueScope(_ raw: String) -> String? {
        let lower = raw.lowercased()
        if lower.contains("app") || lower.contains("application") || lower.contains("software") {
            return "Application"
        }
        if lower.contains("device") || lower.contains("hardware") || lower.contains("machine") {
            return "Device"
        }
        return nil
    }

    /// Builds the default SD+ triage response template.
    private func buildDefaultTriageTemplate(
        turn: AssistantTurn,
        ticketNumber: String,
        location: String?,
        otherUsers: String?,
        issueScope: String?,
        missingItems: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("Ticket: \(ticketNumber)")
        lines.append("Triage Summary")
        lines.append("- Issue: \(turn.intake.issueDescription ?? "Not provided")")
        lines.append("- Device Type: \(turn.intake.deviceType.rawValue)")
        lines.append("- Serial Number: \(turn.intake.serialNumber ?? "Missing")")
        lines.append("- Wi-Fi Network: \(turn.intake.wifiSSID ?? "Missing")")
        lines.append("- App In Use: \(turn.intake.appInUseAtIssueTime ?? "Missing")")
        lines.append("- Location: \(location ?? "Missing")")
        lines.append("- Other Users Impacted: \(otherUsers ?? "Missing")")
        lines.append("- Scope (Application vs Device): \(issueScope ?? "Missing")")
        lines.append("")

        if !missingItems.isEmpty {
            lines.append("Missing Required Data")
            for item in missingItems {
                lines.append("- \(item)")
            }
            lines.append("")
        }

        lines.append("Recommended Troubleshooting Steps")
        if turn.response.steps.isEmpty {
            lines.append("1. Gather missing intake details listed above.")
            lines.append("2. Escalate to Tier 2 if no KB procedure matches.")
        } else {
            for (index, step) in turn.response.steps.enumerated() {
                lines.append("\(index + 1). \(step)")
            }
        }

        lines.append("")
        lines.append("Possible Causes")
        if turn.response.possibleCauses.isEmpty {
            lines.append("- No specific causes identified yet.")
        } else {
            for cause in turn.response.possibleCauses {
                lines.append("- \(cause)")
            }
        }

        if !turn.response.citations.isEmpty {
            lines.append("")
            lines.append("Sources")
            for citation in turn.response.citations {
                lines.append("- \(citation.title) (\(citation.path))")
            }
        }

        let resolution = normalizedOptional(triageResolutionSummary) ?? "[Add final resolution before closing ticket]"
        lines.append("")
        lines.append("Resolution")
        lines.append(resolution)

        return lines.joined(separator: "\n")
    }

    /// Renders a user-saved template using available triage placeholders.
    private func render(
        savedTemplate: SavedResponseTemplate,
        turn: AssistantTurn,
        ticketNumber: String,
        location: String?,
        otherUsers: String?,
        issueScope: String?,
        missingItems: [String]
    ) -> String {
        let steps = turn.response.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let causes = turn.response.possibleCauses.map { "- \($0)" }.joined(separator: "\n")
        let missing = missingItems.map { "- \($0)" }.joined(separator: "\n")
        let sources = turn.response.citations.map { "- \($0.title) (\($0.path))" }.joined(separator: "\n")

        var rendered = savedTemplate.body
        let replacements: [String: String] = [
            "{{ticket_number}}": ticketNumber,
            "{{issue}}": turn.intake.issueDescription ?? "Not provided",
            "{{device_type}}": turn.intake.deviceType.rawValue,
            "{{serial_number}}": turn.intake.serialNumber ?? "Missing",
            "{{wifi_ssid}}": turn.intake.wifiSSID ?? "Missing",
            "{{app_in_use}}": turn.intake.appInUseAtIssueTime ?? "Missing",
            "{{location}}": location ?? "Missing",
            "{{other_users}}": otherUsers ?? "Missing",
            "{{issue_scope}}": issueScope ?? "Missing",
            "{{steps}}": steps,
            "{{possible_causes}}": causes,
            "{{missing_fields}}": missing,
            "{{sources}}": sources,
            "{{resolution}}": normalizedOptional(triageResolutionSummary) ?? "[Add final resolution before closing ticket]"
        ]

        for (token, value) in replacements {
            rendered = rendered.replacingOccurrences(of: token, with: value)
        }

        return rendered
    }
}
