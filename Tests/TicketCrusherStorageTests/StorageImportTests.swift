import Foundation
import XCTest
@testable import TicketCrusherCore
@testable import TicketCrusherStorage

/// Integration-style storage tests for migrations, importing, lookup, and context linking.
final class StorageImportTests: XCTestCase {
    /// Imports a synthetic dataset pack and verifies KB/inventory queries return expected data.
    func testImportAndLookup() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dataRoot = tempRoot.appendingPathComponent("datasets", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)

        let kb = dataRoot.appendingPathComponent("kb_corpus.jsonl")
        let macs = dataRoot.appendingPathComponent("managed_macs.jsonl")
        let mobile = dataRoot.appendingPathComponent("managed_mobile_devices.jsonl")
        let assets = dataRoot.appendingPathComponent("assets.jsonl")
        let intake = dataRoot.appendingPathComponent("apple_intake_filtered.jsonl")
        let policy = dataRoot.appendingPathComponent("cw-support-instructions.json")

        try write(
            """
            {"id":"kb1","title":"Outlook Login","text":"Outlook Login\\nOpen Outlook\\nRemove and re-add the account","source_path":"kb/Outlook Login.json","tags":["outlook","login"]}
            """,
            to: kb
        )

        try write(
            """
            {"type":"managed_mac","source":"410 Computers in _Managed Macs.csv","record":{"Computer Name":"TC-M-TEST","Serial Number":"C02ABC12345","Last Logged-in User":"jdaley","Operating System Version":"15.1","Username":"jdaley@ticketcrusher.com"}}
            """,
            to: macs
        )

        try write(
            """
            {"type":"managed_mobile_device","source":"5745 Mobile Devices in All Managed Devices.csv","record":{"Display Name":"TC iPhone","Model":"iPhone 15","OS Version":"18.1","Serial Number":"DMP123456789","Full Name":"Jim Daley","Device Phone Number":"5551001000"}}
            """,
            to: mobile
        )

        try write(
            """
            {"type":"asset_record","source":"assets.csv","record":{"Name":"TC-Laptop-01","User.Name":"jim.daley","Product.Product Name":"MacBook Pro","AssetTag":"AT-1001","Asset Category.Name":"IT"}}
            """,
            to: assets
        )

        try write(
            """
            {"type":"apple_intake_record","source":"Apple Intake.xlsx (filtered)","record":{"Scan":"C02ABC12345","Serial Number":"C02ABC12345","Device/Item":"MacBook Pro","SD+":"Added"}}
            """,
            to: intake
        )

        try write(
            """
            {
              "scope": {"supported_platforms": ["macOS", "iOS", "iPadOS"], "device_requirement": "Apple only"},
              "ticket_detection": {"trigger_format": "##<ticket_number>"},
              "user_annotations": {"comment_prefix": "//"},
              "intake_and_validation": {"required_details": ["device_type","serial_number","issue_description","app_in_use_at_time_of_issue","wifi_ssid_connected_to"]}
            }
            """,
            to: policy
        )

        let databaseURL = tempRoot.appendingPathComponent("ticketcrusher.sqlite")
        let db = try SQLiteDatabase(databaseURL: databaseURL)
        try DatabaseMigrator(database: db).migrate()

        let importer = DataPackImporter(database: db)
        let config = DataPackConfiguration(
            rootDirectory: dataRoot,
            knowledgeBasePath: kb,
            managedMacsPath: macs,
            managedMobilePath: mobile,
            assetsPath: assets,
            appleIntakePath: intake,
            workflowPolicyPath: policy
        )

        let report = try importer.importAll(from: config)
        XCTAssertEqual(report.importedFiles.count, 5)

        let kbRepository = SQLiteKBRepository(database: db)
        let kbResults = try kbRepository.search(KBSearchQuery(text: "outlook login", preferredDevice: .mac), limit: 5)
        XCTAssertFalse(kbResults.isEmpty)

        let inventoryRepository = SQLiteInventoryRepository(database: db)
        let serialResults = try inventoryRepository.lookup(
            InventoryLookupQuery(text: "C02ABC12345", field: .serialNumber),
            limit: 10
        )
        XCTAssertFalse(serialResults.isEmpty)

        let linked = try inventoryRepository.linkedContext(serialNumber: "C02ABC12345", username: nil)
        XCTAssertGreaterThan(linked.confidence, 0.9)
    }

    /// Helper for writing fixture files with normalized trailing newline.
    private func write(_ string: String, to url: URL) throws {
        try string.trimmingCharacters(in: .whitespacesAndNewlines)
            .appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
