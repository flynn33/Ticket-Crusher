# Ticket Crusher (macOS, SwiftUI)

This project is a modular Swift package that opens directly in Xcode and builds a native macOS support workflow app.

## About
Developed by Jim Daley.

## Open In Xcode
1. Open Xcode.
2. Choose **File > Open...** and select:
   `<project-root>/ticket-crushers.xcodeproj`
3. Select the `TicketCrusherApp` scheme.
4. Run (`Cmd+R`).

You can also open the Swift package directly at `Package.swift` if preferred.

## Regenerate Xcode Project
If you add/remove source files, regenerate the project with:

```bash
ruby scripts/generate_xcodeproj.rb
```

## First Run
1. Go to the **Settings** tab.
2. Set dataset root path (default):
   `<project-root>/datasets`
3. Click **Import / Refresh Data**.

The app will import:
- Explicit known files when present:
  - `kb_corpus.jsonl`
  - `managed_macs.jsonl`
  - `managed_mobile_devices.jsonl`
  - `assets.jsonl`
  - `apple_intake_filtered.jsonl`
  - workflow rules from `cw-support-instructions.json`
- Plus auto-discovered dataset files under the selected root for supported extensions:
  - `.csv`, `.json`, `.jsonl`, `.txt`, `.md`, `.markdown`, `.pdf`, `.docx`, `.doxs`, `.doc`, `.rtf`, `.xlsx`, `.xls`, `.log`

## Modules
- `TicketCrusherApp`: SwiftUI screens (Home, Chat, KB Library, Asset Lookup, Settings, Exports)
- `TicketCrusherCore`: domain models, protocols, policy model
- `TicketCrusherStorage`: SQLite schema/migrations/importers/repositories
- `TicketCrusherFeatures`: ticket parser, intake state machine, orchestration, response/export logic
- `TicketCrusherIntegrations`: Jamf/ServiceDeskPlus stubs + pluggable interfaces
- `TicketCrusherChecks`: automated validation executable

## Validation
XCTest is not available in this toolchain, so validation is provided by a runnable checks target:

```bash
swift run TicketCrusherChecks
```

Expected output:

```text
TicketCrusherChecks passed
```

## Key Workflow Behavior
- Ticket workflow trigger: message starts with `##<ticket_number>`
- `//` lines are parsed as authoritative annotations
- Required intake fields enforced before troubleshooting:
  - device type (Apple only)
  - serial number
  - issue description
  - app in use
  - Wi-Fi SSID
- Response order:
  1. Troubleshooting steps
  2. Possible causes
  3. What I need from you (when intake incomplete)
  4. Sources (citations)
