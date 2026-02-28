import SwiftUI
import TicketCrusherCore

/// Stable tab identifiers used for programmatic tab navigation from the Home view.
enum AppTab: Hashable {
    case home
    case ticketTriage
    case kbLibrary
    case assetLookup
    case settings
    case exports
}

/// Reusable info button that opens an inline guidance popover for the current view.
struct InfoPopoverButton: View {
    let title: String
    let message: String

    @State private var isPresented = false

    /// Renders the `i` button and a lightweight help popover.
    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .help(title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
    }
}

/// Root tab container that wires each major feature screen to one shared view model.
struct RootView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var selectedTab: AppTab = .home

    /// Renders the main navigation tabs for triage, search, settings, and exports.
    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(viewModel: viewModel, selectedTab: $selectedTab)
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(AppTab.home)

            ChatView(viewModel: viewModel)
                .tabItem {
                    Label("Ticket Triage", systemImage: "bolt.fill")
                }
                .tag(AppTab.ticketTriage)

            KBLibraryView(viewModel: viewModel)
                .tabItem {
                    Label("KB Library", systemImage: "books.vertical")
                }
                .tag(AppTab.kbLibrary)

            AssetLookupView(viewModel: viewModel)
                .tabItem {
                    Label("Asset Lookup", systemImage: "desktopcomputer")
                }
                .tag(AppTab.assetLookup)

            SettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppTab.settings)

            ExportsView(viewModel: viewModel)
                .tabItem {
                    Label("Exports", systemImage: "square.and.arrow.up")
                }
                .tag(AppTab.exports)
        }
        .frame(minWidth: 1100, minHeight: 740)
    }
}

/// Dashboard landing screen with quick mode summaries and a recent conversation preview.
struct HomeView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var selectedTab: AppTab

    /// Shows high-level app purpose, mode cards, and current status text.
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            BrandingMarkView(maxHeight: 84)

            HStack(spacing: 10) {
                Text("Ticket Crusher")
                    .font(.largeTitle)
                if let icon = AppBrandingAssets.ticketCrusherIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                        .accessibilityLabel("Ticket Crusher icon")
                }
            }
            Text("Developed by Jim Daley")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Choose a feature card below to jump directly into the workflow you need.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("Modes")
                    .font(.title3)
                InfoPopoverButton(
                    title: "Feature Cards",
                    message: "Each card opens the corresponding tab. Use Ticket Triage for intake and template creation, KB Library for procedure search, Asset Lookup for inventory lookups, and Settings for data import."
                )
            }

            HStack(spacing: 12) {
                modeCard(
                    title: "Ticket Triage",
                    description: "Guided intake workflow with ticket support and template creation.",
                    destination: .ticketTriage
                )
                modeCard(
                    title: "KB Library",
                    description: "Browse and search internal procedures offline.",
                    destination: .kbLibrary
                )
                modeCard(
                    title: "Asset Lookup",
                    description: "Search local inventory exports by serial, user, and asset tag.",
                    destination: .assetLookup
                )
                modeCard(
                    title: "Settings",
                    description: "Import and refresh datasets from Finder.",
                    destination: .settings
                )
            }

            Divider()

            Text("Recent Conversation")
                .font(.title3)

            if viewModel.recentConversationPreview.isEmpty {
                Text("No messages yet.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.recentConversationPreview) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.role == .user ? "User" : "Assistant")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(message.text)
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            Spacer()
            Text(viewModel.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    /// Reusable summary card used in the Home tab for quick mode descriptions.
    private func modeCard(title: String, description: String, destination: AppTab) -> some View {
        Button {
            selectedTab = destination
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 118, alignment: .topLeading)
            .padding(12)
            .background(Color.gray.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.gray.opacity(0.22), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// Chat interface for guided support intake and deterministic troubleshooting responses.
struct ChatView: View {
    @ObservedObject var viewModel: AppViewModel

    /// Displays the transcript, message entry field, and send/reset actions.
    var body: some View {
        // Wrap the entire triage layout in a parent scroll view so long responses never lock vertical navigation.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Ticket Triage")
                        .font(.title2)
                    InfoPopoverButton(
                        title: "Ticket Triage",
                        message: "Paste the SD+ ticket, enter the ticket number, and press Crush It. The app checks missing required data, builds a response template, and lets you save templates and resolutions."
                    )
                    Spacer()
                    Button("Reset") {
                        viewModel.resetConversation()
                    }
                }

                BrandingMarkView(maxHeight: 58)
                Text("Use this view to triage SD+ tickets, generate response templates, and track ticket outcomes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Ticket Number", text: $viewModel.triageTicketNumber)
                            .textFieldStyle(.roundedBorder)

                        Text("Paste SD+ Ticket Details")
                            .font(.headline)
                        TextEditor(text: $viewModel.triageTicketText)
                            .frame(minHeight: 190)
                            .padding(6)
                            .background(Color.gray.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        HStack(spacing: 12) {
                            Button("Crush It") {
                                viewModel.crushTicket()
                            }
                            .keyboardShortcut(.return, modifiers: [.command])
                            Button("Copy Template") {
                                viewModel.copyTriageTemplate()
                            }
                            Button("Save Resolution") {
                                viewModel.saveTriageResolution()
                            }
                        }

                        if !viewModel.triageMissingItems.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Missing Required Data")
                                    .font(.headline)
                                ForEach(viewModel.triageMissingItems, id: \.self) { item in
                                    Text("- \(item)")
                                        .font(.caption)
                                }
                            }
                        }

                        Text("Generated SD+ Response Template")
                            .font(.headline)
                        TextEditor(text: $viewModel.triageResponseTemplate)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 220)
                            .padding(6)
                            .background(Color.gray.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text("Resolution Notes")
                            .font(.headline)
                        TextEditor(text: $viewModel.triageResolutionSummary)
                            .frame(minHeight: 72, maxHeight: 110)
                            .padding(6)
                            .background(Color.gray.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Saved Response Templates")
                            .font(.headline)
                        TextField("Template Name", text: $viewModel.templateNameDraft)
                            .textFieldStyle(.roundedBorder)
                        TextEditor(text: $viewModel.templateBodyDraft)
                            .frame(minHeight: 110, maxHeight: 150)
                            .padding(6)
                            .background(Color.gray.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        HStack(spacing: 10) {
                            Button("Save Template") {
                                viewModel.saveResponseTemplateDraft()
                            }
                            Button("Delete Selected") {
                                viewModel.deleteSelectedTemplate()
                            }
                        }

                        List(viewModel.savedTemplates, id: \.id) { template in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(template.name)
                                        .font(.headline)
                                    Text(template.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Load") {
                                    viewModel.loadResponseTemplate(template)
                                }
                            }
                        }
                        .frame(minHeight: 150, maxHeight: 190)

                        Text("Tracked Tickets and Resolutions")
                            .font(.headline)
                        List(viewModel.recentTrackedTickets, id: \.id) { record in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(record.ticketNumber)
                                        .font(.headline)
                                    Text(record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Load") {
                                    viewModel.loadTrackedTicket(record)
                                }
                            }
                        }
                        .frame(minHeight: 220)
                    }
                    .frame(width: 360)
                }

                if !viewModel.messages.isEmpty {
                    Text("Recent Triage Activity")
                        .font(.headline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.recentConversationPreview) { message in
                                Text("\(message.role == .user ? "User" : "Assistant"): \(message.text)")
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Color.gray.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 160)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// KB search screen for browsing ingested articles and reading full procedure text.
struct KBLibraryView: View {
    @ObservedObject var viewModel: AppViewModel

    /// Renders searchable KB results with a split view for article details.
    var body: some View {
        VStack(spacing: 12) {
            BrandingMarkView(maxHeight: 44)
            HStack(spacing: 6) {
                Text("KB Library")
                    .font(.title2)
                InfoPopoverButton(
                    title: "KB Library",
                    message: "Search imported procedures and click any result to read the full article. Import more files from Settings to expand the knowledge base."
                )
                Spacer()
            }
            Text("Search terms match article titles, body text, and tags from your imported content.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Search KB", text: $viewModel.kbSearchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.searchKB()
                    }
                Button("Search") {
                    viewModel.searchKB()
                }
            }

            HStack(spacing: 12) {
                List(selection: Binding<String?>(
                    get: { viewModel.selectedKBArticle?.id },
                    set: { selectedID in
                        guard let selectedID else { return }
                        viewModel.selectedKBArticle = viewModel.kbResults.first(where: { $0.article.id == selectedID })?.article
                    }
                )) {
                    ForEach(viewModel.kbResults, id: \.article.id) { result in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.article.title)
                            Text(result.article.sourcePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minWidth: 350)

                VStack(alignment: .leading, spacing: 10) {
                    if let article = viewModel.selectedKBArticle {
                        Text(article.title)
                            .font(.title2)
                        Text(article.sourcePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                        ScrollView {
                            Text(article.bodyText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("Select an article")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
                .background(Color.gray.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(20)
    }
}

/// Inventory lookup interface for matching users/devices by serial, tag, or identity fields.
struct AssetLookupView: View {
    @ObservedObject var viewModel: AppViewModel

    /// Shows lookup controls and a normalized list of matched inventory records.
    var body: some View {
        VStack(spacing: 12) {
            BrandingMarkView(maxHeight: 44)
            HStack(spacing: 6) {
                Text("Asset Lookup")
                    .font(.title2)
                InfoPopoverButton(
                    title: "Asset Lookup",
                    message: "Search by serial number, username, asset tag, display name, or phone number to find ingested inventory records across sources."
                )
                Spacer()
            }
            Text("Use broad terms or exact identifiers to quickly locate devices and ownership context.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Search serial, user, asset tag, name, or phone", text: $viewModel.assetSearchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.lookupAssets()
                    }
                Button("Lookup") {
                    viewModel.lookupAssets()
                }
            }

            List(viewModel.assetResults, id: \.id) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.displayName ?? record.serialNumber ?? "Unknown record")
                        .font(.headline)
                    Text("Source: \(record.sourceType.rawValue) / \(record.source)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        [
                            record.serialNumber.map { "Serial: \($0)" },
                            record.username.map { "User: \($0)" },
                            record.osVersion.map { "OS: \($0)" },
                            record.model.map { "Model: \($0)" },
                            record.assetTag.map { "Asset Tag: \($0)" }
                        ]
                        .compactMap { $0 }
                        .joined(separator: " | ")
                    )
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
    }
}

/// Settings panel for dataset import configuration, status feedback, and application attribution.
struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    /// Renders import controls, runtime status, and the About section.
    var body: some View {
        Form {
            Section("How To Use") {
                HStack(spacing: 6) {
                    Text("Data Ingestion Help")
                        .font(.headline)
                    InfoPopoverButton(
                        title: "Settings and Data Import",
                        message: "Choose a folder, then use Import Files to add CSV/JSON/MD/TXT/PDF/DOCX/XLSX/ZIP data. Import / Refresh Data runs ingestion, normalizes records, and refreshes the local search indexes."
                    )
                }
                Text("If no dataset directory exists, the app creates one and stores imported files there automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data Pack") {
                TextField("Dataset root path", text: $viewModel.dataPackRootPath)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 12) {
                    Button("Choose Folder...") {
                        viewModel.chooseDatasetFolder()
                    }
                    Button("Import Files...") {
                        viewModel.importFromFinder()
                    }
                    Button("Import / Refresh Data") {
                        viewModel.importData()
                    }
                }
                Text("Supports common formats including .csv, .json, .jsonl, .txt, .md, .pdf, .docx, .xlsx, and more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                HStack(spacing: 6) {
                    Text("Diagnostic Logs")
                        .font(.headline)
                    InfoPopoverButton(
                        title: "Diagnostics View",
                        message: "This panel stores app and ingestion errors for 30 days. Select a log to read details and use Export Logs to save a .txt file for troubleshooting."
                    )
                    Spacer()
                    Button("Refresh Logs") {
                        viewModel.refreshDiagnostics()
                    }
                    Button("Export Logs (.txt)") {
                        viewModel.exportDiagnosticsAsText()
                    }
                }

                Text("Select a log entry to inspect full error details, context, and call stack.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 12) {
                    List(
                        selection: Binding<Int64?>(
                            get: { viewModel.selectedDiagnosticLogID },
                            set: { viewModel.selectDiagnosticLog($0) }
                        )
                    ) {
                        ForEach(viewModel.diagnosticLogs, id: \.id) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(entry.level.rawValue.uppercased())
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.gray.opacity(0.18))
                                        .clipShape(Capsule())
                                    Text(entry.category)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.message)
                                    .font(.subheadline)
                                    .lineLimit(2)
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Optional(entry.id))
                        }
                    }
                    .frame(minWidth: 350, minHeight: 240, maxHeight: 300)

                    VStack(alignment: .leading, spacing: 8) {
                        if let selected = viewModel.selectedDiagnosticLog {
                            Text("Log Details")
                                .font(.headline)
                            ScrollView {
                                Text(diagnosticsDetailText(for: selected))
                                    .font(.system(.body, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text("Select a diagnostic log to view details.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 300, alignment: .topLeading)
                    .padding(10)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            Section("Status") {
                Text(viewModel.statusText)
                    .textSelection(.enabled)
            }

            Section("About") {
                BrandingMarkView(maxHeight: 52)
                Text("Developed by Jim Daley")
                    .font(.body)
            }
        }
        .padding(20)
        .onAppear {
            viewModel.refreshDiagnostics()
        }
    }

    /// Formats one diagnostics entry into a readable details block.
    private func diagnosticsDetailText(for entry: DiagnosticLogEntry) -> String {
        var lines: [String] = []
        lines.append("ID: \(entry.id)")
        lines.append("Level: \(entry.level.rawValue.uppercased())")
        lines.append("Category: \(entry.category)")
        lines.append("Date: \(entry.createdAt.formatted(date: .abbreviated, time: .standard))")
        lines.append("")
        lines.append("Message")
        lines.append(entry.message)

        if let details = entry.details, !details.isEmpty {
            lines.append("")
            lines.append("Details")
            lines.append(details)
        }

        return lines.joined(separator: "\n")
    }
}

/// Reusable Ticket Crusher branding view used across tabs to reinforce app identity.
struct BrandingMarkView: View {
    let maxHeight: CGFloat

    /// Renders the packaged Ticket Crusher branding art.
    var body: some View {
        HStack(spacing: 14) {
            if let branding = AppBrandingAssets.ticketCrusherBranding {
                Image(nsImage: branding)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: maxHeight)
                    .accessibilityLabel("Ticket Crusher branding")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Export view for copying ticket-ready troubleshooting summaries.
struct ExportsView: View {
    @ObservedObject var viewModel: AppViewModel

    /// Displays generated export text and a one-click copy action.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandingMarkView(maxHeight: 44)

            HStack {
                Text("Ticket Export")
                    .font(.title2)
                InfoPopoverButton(
                    title: "Ticket Export",
                    message: "This field contains both an end-user follow-up script and the technician template. The follow-up includes rotating empathetic language and polite requests for any missing intake details."
                )
                Spacer()
                Button("Copy") {
                    viewModel.copyExport()
                }
            }
            Text("Review and adjust both sections before copying into SD+.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $viewModel.exportText)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
    }
}
