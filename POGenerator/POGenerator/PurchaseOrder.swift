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
    var status: POStatus
    var statusUpdatedByName: String?
    var statusUpdatedAt: Date?

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
        status: POStatus = .new,
        statusUpdatedByName: String? = nil,
        statusUpdatedAt: Date? = nil
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
        self.status = status
        self.statusUpdatedByName = statusUpdatedByName
        self.statusUpdatedAt = statusUpdatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, poNumber, jobNumber, customerName, sequence, createdAt, details, photoFileName, createdByName
        case status, statusUpdatedByName, statusUpdatedAt
        // Pre-status builds tracked a single fulfilled flag; decoded below for migration.
        case isFulfilled, fulfilledByName, fulfilledAt
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

        if let decodedStatus = try container.decodeIfPresent(POStatus.self, forKey: .status) {
            status = decodedStatus
            statusUpdatedByName = try container.decodeIfPresent(String.self, forKey: .statusUpdatedByName)
            statusUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .statusUpdatedAt)
        } else {
            let wasFulfilled = try container.decodeIfPresent(Bool.self, forKey: .isFulfilled) ?? false
            status = wasFulfilled ? .fulfilled : .new
            statusUpdatedByName = try container.decodeIfPresent(String.self, forKey: .fulfilledByName)
            statusUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .fulfilledAt)
        }
    }
}
