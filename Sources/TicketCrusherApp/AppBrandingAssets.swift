import AppKit
import Foundation

/// Centralized lookup for visual branding resources bundled with the app.
/// Developed by Jim Daley.
enum AppBrandingAssets {
    /// Shared bundle accessor that works for both Swift package and generated Xcode project builds.
    private static var resourceBundle: Bundle {
#if SWIFT_PACKAGE
        return .module
#else
        return .main
#endif
    }

    /// Resolves a PNG resource by basename and loads it as an NSImage.
    private static func image(named resourceName: String) -> NSImage? {
        guard let resourceURL = resourceBundle.url(forResource: resourceName, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: resourceURL)
    }

    /// App dock icon used at runtime to brand the macOS application window and dock tile.
    static var ticketCrusherIcon: NSImage? {
        image(named: "ticket_crusher_icon")
    }

    /// Ticket Crusher brand mark used inside app views.
    static var ticketCrusherBranding: NSImage? {
        image(named: "ticket_crusher_branding")
    }
}
