import Foundation

struct PurchaseOrder: Identifiable, Hashable, Codable {
    let id: String
    let poNumber: String
    let jobNumber: String
    let customerName: String
    let sequence: Int
    let createdAt: Date
    let details: String
    let photoFileName: String?
    let createdByName: String
    var isFulfilled: Bool
    var fulfilledByName: String?
    var fulfilledAt: Date?

    init(
        id: String,
        poNumber: String,
        jobNumber: String,
        customerName: String,
        sequence: Int,
        createdAt: Date,
        details: String,
        photoFileName: String?,
        createdByName: String,
        isFulfilled: Bool,
        fulfilledByName: String?,
        fulfilledAt: Date?
    ) {
        self.id = id
        self.poNumber = poNumber
        self.jobNumber = jobNumber
        self.customerName = customerName
        self.sequence = sequence
        self.createdAt = createdAt
        self.details = details
        self.photoFileName = photoFileName
        self.createdByName = createdByName
        self.isFulfilled = isFulfilled
        self.fulfilledByName = fulfilledByName
        self.fulfilledAt = fulfilledAt
    }

    // Fields added after v1 decode leniently so history saved by an older build
    // (or a future one that drops a field) never fails wholesale and wipes itself.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        poNumber = try container.decode(String.self, forKey: .poNumber)
        jobNumber = try container.decode(String.self, forKey: .jobNumber)
        customerName = try container.decode(String.self, forKey: .customerName)
        sequence = try container.decode(Int.self, forKey: .sequence)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        details = try container.decodeIfPresent(String.self, forKey: .details) ?? ""
        photoFileName = try container.decodeIfPresent(String.self, forKey: .photoFileName)
        createdByName = try container.decodeIfPresent(String.self, forKey: .createdByName) ?? ""
        isFulfilled = try container.decodeIfPresent(Bool.self, forKey: .isFulfilled) ?? false
        fulfilledByName = try container.decodeIfPresent(String.self, forKey: .fulfilledByName)
        fulfilledAt = try container.decodeIfPresent(Date.self, forKey: .fulfilledAt)
    }
}
