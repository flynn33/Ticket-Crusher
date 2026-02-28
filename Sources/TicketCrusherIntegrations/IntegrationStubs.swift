import Foundation
import TicketCrusherCore

/// Shared integration error used by stub connectors when services are not configured.
public enum IntegrationError: LocalizedError {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

/// Jamf client stub that clearly reports unconfigured integration behavior.
public final class UnavailableJamfClient: JamfClient {
    public init() {}

    /// Fails computer lookup with an actionable configuration message.
    public func lookupComputer(serial: String) async throws -> [String: String] {
        throw IntegrationError.unavailable("Jamf integration is not configured. Falling back to local inventory export.")
    }

    /// Fails mobile lookup with an actionable configuration message.
    public func lookupMobileDevice(serial: String) async throws -> [String: String] {
        throw IntegrationError.unavailable("Jamf integration is not configured. Falling back to local inventory export.")
    }
}

/// ServiceDesk Plus client stub that preserves interface behavior until wired to a real API.
public final class UnavailableSDPClient: SDPClient {
    public init() {}

    /// Fails ticket retrieval when integration settings are unavailable.
    public func getTicket(id: String) async throws -> [String: String] {
        throw IntegrationError.unavailable("ServiceDeskPlus integration is not configured.")
    }

    /// Fails note creation when integration settings are unavailable.
    public func addNote(id: String, text: String) async throws {
        throw IntegrationError.unavailable("ServiceDeskPlus integration is not configured.")
    }

    /// Fails ticket creation when integration settings are unavailable.
    public func createTicket(payload: [String: String]) async throws -> String {
        throw IntegrationError.unavailable("ServiceDeskPlus integration is not configured.")
    }
}

/// Minimal LLM provider stub that keeps the app in retrieval-only mode.
public final class NullLLMProvider: LLMProvider {
    public init() {}

    /// Returns a fixed response indicating no remote model is configured.
    public func generate(prompt: String, context: String) async throws -> String {
        "Local retrieval mode enabled. No remote LLM configured."
    }
}
