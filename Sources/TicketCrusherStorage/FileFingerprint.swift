import CryptoKit
import Foundation

/// Fingerprint payload used to detect whether a source file changed since last import.
struct FileFingerprint {
    let sha256: String
    let modifiedTime: Double

    /// Computes SHA-256 and modification time for an on-disk file.
    static func make(for fileURL: URL) throws -> FileFingerprint {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
        let sha256 = digest.map { String(format: "%02x", $0) }.joined()

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modified = (attrs[.modificationDate] as? Date) ?? Date.distantPast

        return FileFingerprint(sha256: sha256, modifiedTime: modified.timeIntervalSince1970)
    }
}
