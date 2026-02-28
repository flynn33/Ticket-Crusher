import AppKit
import SwiftUI

/// Application entry point for the macOS Ticket Crusher app.
/// Developed by Jim Daley.
@main
struct TicketCrusherAppMain: App {
    /// Applies app-wide visual branding that should be present as soon as the app launches.
    init() {
        if let icon = AppBrandingAssets.ticketCrusherIcon {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    /// Builds the primary window scene that hosts the tabbed root view.
    var body: some Scene {
        WindowGroup("Ticket Crusher") {
            RootView()
        }
    }
}
