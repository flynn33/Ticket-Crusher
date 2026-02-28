import Foundation
import TicketCrusherCore

/// Thin service wrapper around KB repository search for UI and orchestrator usage.
public struct KnowledgeRetrievalService {
    private let kbRepository: KBRepository

    public init(kbRepository: KBRepository) {
        self.kbRepository = kbRepository
    }

    /// Executes a KB query with optional device/app ranking preferences.
    public func search(
        query: String,
        preferredDevice: DeviceType? = nil,
        preferredApp: String? = nil,
        limit: Int = 20
    ) throws -> [KBSearchResult] {
        try kbRepository.search(
            KBSearchQuery(text: query, preferredDevice: preferredDevice, preferredApp: preferredApp),
            limit: limit
        )
    }
}
