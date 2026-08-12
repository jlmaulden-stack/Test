import Foundation

/// A single receipt attached to a PO: one photo plus its own dollar amount.
struct Receipt: Identifiable, Hashable, Codable {
    let id: String
    var photoFileName: String
    var amount: Double?

    init(id: String = UUID().uuidString, photoFileName: String, amount: Double? = nil) {
        self.id = id
        self.photoFileName = photoFileName
        self.amount = amount
    }
}
