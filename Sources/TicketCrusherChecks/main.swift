import Foundation
import TicketCrusherCore
import TicketCrusherFeatures
import TicketCrusherStorage

/// Lightweight error used by command-line validation checks.
struct CheckFailure: Error {
    let message: String
}

/// Throws `CheckFailure` when a validation assertion is false.
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CheckFailure(message: message)
    }
}

/// Validates parser, intake workflow, and response formatting behavior.
func runParserChecks() throws {
    let parser = TicketParser(policy: .default())
    let message = """
    ##INC12345
    Device: MacBook Pro
    Serial: C02TEST12345
    App: Outlook
    SSID: TC-Corp
    // User reports issue started after password change
    Issue: Outlook keeps prompting for credentials
    """

    let result = parser.parse(message: message)

    try expect(result.isTicketMessage, "Ticket message was not detected")
    try expect(result.intake.ticketNumber == "INC12345", "Ticket number parse failed")
    try expect(result.intake.deviceType == .mac, "Device parsing failed")
    try expect(result.intake.serialNumber == "C02TEST12345", "Serial parsing failed")

    let machine = IntakeStateMachine()
    var intake = result.intake
    intake.issueDescription = nil
    let assessment = machine.assess(intake)
    try expect(assessment.state == .missingIssue, "Intake state machine sequence failed")

    let composer = ResponseComposer()
    let rendered = composer.render(response: BotResponse(
        steps: ["Step 1"],
        possibleCauses: ["Cause 1"]
    ))
    try expect(rendered.contains("Troubleshooting steps"), "Composer missing steps section")
    try expect(rendered.contains("Possible causes"), "Composer missing causes section")
}

/// Validates storage migration, import, KB lookup, and inventory lookup behavior.
func runStorageChecks() throws {
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
        {"id":"kb1","title":"Outlook Login","text":"Outlook Login\\nOpen Outlook\\nRemove and re-add account","source_path":"kb/Outlook Login.json","tags":["outlook","login"]}
        """,
        to: kb
    )
    try write(
        """
        {"type":"managed_mac","source":"managed_macs.csv","record":{"Computer Name":"TC-M-TEST","Serial Number":"C02ABC12345","Username":"jdaley@ticketcrusher.com","Operating System Version":"15.1"}}
        """,
        to: macs
    )
    try write(
        """
        {"type":"managed_mobile_device","source":"managed_mobile_devices.csv","record":{"Display Name":"TC iPhone","Model":"iPhone 15","OS Version":"18.1","Serial Number":"DMP123456789","Full Name":"Jim Daley","Device Phone Number":"5551001000"}}
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
    try expect(report.importedFiles.count == 5, "Not all files imported")

    let kbRepository = SQLiteKBRepository(database: db)
    let kbResults = try kbRepository.search(
        KBSearchQuery(text: "outlook login", preferredDevice: .mac),
        limit: 3
    )
    try expect(!kbResults.isEmpty, "KB lookup failed")

    let inventoryRepository = SQLiteInventoryRepository(database: db)
    let inventory = try inventoryRepository.lookup(
        InventoryLookupQuery(text: "C02ABC12345", field: .serialNumber),
        limit: 3
    )
    try expect(!inventory.isEmpty, "Inventory lookup failed")
}

/// Writes fixture text to disk with normalized trailing newline.
func write(_ text: String, to url: URL) throws {
    try text.trimmingCharacters(in: .whitespacesAndNewlines)
        .appending("\n")
        .write(to: url, atomically: true, encoding: .utf8)
}

/// Entry point for command-line validation target.
do {
    try runParserChecks()
    try runStorageChecks()
    print("TicketCrusherChecks passed")
} catch {
    fputs("TicketCrusherChecks failed: \(error)\n", stderr)
    exit(1)
}
