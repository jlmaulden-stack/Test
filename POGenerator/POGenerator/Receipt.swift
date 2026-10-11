import Foundation

/// A single receipt attached to a PO: one or more photos (a long receipt often needs
/// several shots, and a partial delivery can arrive with a multi-page invoice) plus
/// the one dollar amount they add up to.
struct Receipt: Identifiable, Hashable, Codable {
    let id: String
    var photoFileNames: [String]
    var amount: Double?

    init(id: String = UUID().uuidString, photoFileNames: [String], amount: Double? = nil) {
        self.id = id
        self.photoFileNames = photoFileNames
        self.amount = amount
    }

    /// Convenience for the single-photo case.
    init(id: String = UUID().uuidString, photoFileName: String, amount: Double? = nil) {
        self.init(id: id, photoFileNames: [photoFileName], amount: amount)
    }

    /// The photo shown as the receipt's thumbnail.
    var primaryPhotoFileName: String? { photoFileNames.first }

    private enum CodingKeys: String, CodingKey {
        case id, photoFileNames, amount
    }

    // Single-photo key from older builds, kept out of CodingKeys so Encodable synthesis
    // still works. Read only during migration.
    private enum LegacyCodingKeys: String, CodingKey {
        case photoFileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        amount = try container.decodeIfPresent(Double.self, forKey: .amount)

        if let names = try container.decodeIfPresent([String].self, forKey: .photoFileNames) {
            photoFileNames = names
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let single = try legacy.decodeIfPresent(String.self, forKey: .photoFileName)
            photoFileNames = single.map { [$0] } ?? []
        }
    }
}
