import Foundation

struct PurchaseOrder: Identifiable, Hashable, Codable {
    let id: String
    // Assigned at approval time; empty/0 while a request is pending approval.
    var poNumber: String
    let jobNumber: String
    let customerName: String
    var sequence: Int
    let createdAt: Date
    let details: String
    let photoFileNames: [String]
    let createdByName: String
    var isApproved: Bool
    var approvedByName: String?
    var approvedAt: Date?
    var wasSelfApproved: Bool
    var status: POStatus
    var statusUpdatedByName: String?
    var statusUpdatedAt: Date?
    var fulfillmentNotes: String
    var receipts: [Receipt]

    /// Sum of every receipt's amount, ignoring receipts with no amount entered.
    var totalAmount: Double? {
        let amounts = receipts.compactMap(\.amount)
        return amounts.isEmpty ? nil : amounts.reduce(0, +)
    }

    init(
        id: String,
        poNumber: String,
        jobNumber: String,
        customerName: String,
        sequence: Int,
        createdAt: Date,
        details: String,
        photoFileNames: [String] = [],
        createdByName: String,
        isApproved: Bool = true,
        approvedByName: String? = nil,
        approvedAt: Date? = nil,
        wasSelfApproved: Bool = false,
        status: POStatus = .new,
        statusUpdatedByName: String? = nil,
        statusUpdatedAt: Date? = nil,
        fulfillmentNotes: String = "",
        receipts: [Receipt] = []
    ) {
        self.id = id
        self.poNumber = poNumber
        self.jobNumber = jobNumber
        self.customerName = customerName
        self.sequence = sequence
        self.createdAt = createdAt
        self.details = details
        self.photoFileNames = photoFileNames
        self.createdByName = createdByName
        self.isApproved = isApproved
        self.approvedByName = approvedByName
        self.approvedAt = approvedAt
        self.wasSelfApproved = wasSelfApproved
        self.status = status
        self.statusUpdatedByName = statusUpdatedByName
        self.statusUpdatedAt = statusUpdatedAt
        self.fulfillmentNotes = fulfillmentNotes
        self.receipts = receipts
    }

    private enum CodingKeys: String, CodingKey {
        case id, poNumber, jobNumber, customerName, sequence, createdAt, details, photoFileNames, createdByName
        case isApproved, approvedByName, approvedAt, wasSelfApproved
        case status, statusUpdatedByName, statusUpdatedAt, fulfillmentNotes, receipts
    }

    // Keys from older builds, kept out of CodingKeys so Encodable synthesis still works
    // (every CodingKeys case must be a stored property). Read only during migration.
    private enum LegacyCodingKeys: String, CodingKey {
        case isFulfilled, fulfilledByName, fulfilledAt
        case photoFileName, receiptPhotoFileName, amount
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
        createdByName = try container.decodeIfPresent(String.self, forKey: .createdByName) ?? ""
        fulfillmentNotes = try container.decodeIfPresent(String.self, forKey: .fulfillmentNotes) ?? ""

        // Records from before the approval feature already have numbers, so treat them
        // as approved.
        isApproved = try container.decodeIfPresent(Bool.self, forKey: .isApproved) ?? true
        approvedByName = try container.decodeIfPresent(String.self, forKey: .approvedByName)
        approvedAt = try container.decodeIfPresent(Date.self, forKey: .approvedAt)
        wasSelfApproved = try container.decodeIfPresent(Bool.self, forKey: .wasSelfApproved) ?? false

        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)

        // Submission photos: multiple now; migrate a single legacy photoFileName.
        if let names = try container.decodeIfPresent([String].self, forKey: .photoFileNames) {
            photoFileNames = names
        } else if let single = try legacy.decodeIfPresent(String.self, forKey: .photoFileName) {
            photoFileNames = [single]
        } else {
            photoFileNames = []
        }

        // Receipts: list of photo+amount now; migrate a single legacy receipt+amount.
        if let decodedReceipts = try container.decodeIfPresent([Receipt].self, forKey: .receipts) {
            receipts = decodedReceipts
        } else if let legacyReceipt = try legacy.decodeIfPresent(String.self, forKey: .receiptPhotoFileName) {
            let legacyAmount = try legacy.decodeIfPresent(Double.self, forKey: .amount)
            receipts = [Receipt(photoFileName: legacyReceipt, amount: legacyAmount)]
        } else {
            receipts = []
        }

        if let decodedStatus = try container.decodeIfPresent(POStatus.self, forKey: .status) {
            status = decodedStatus
            statusUpdatedByName = try container.decodeIfPresent(String.self, forKey: .statusUpdatedByName)
            statusUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .statusUpdatedAt)
        } else {
            let wasFulfilled = try legacy.decodeIfPresent(Bool.self, forKey: .isFulfilled) ?? false
            status = wasFulfilled ? .fulfilled : .new
            statusUpdatedByName = try legacy.decodeIfPresent(String.self, forKey: .fulfilledByName)
            statusUpdatedAt = try legacy.decodeIfPresent(Date.self, forKey: .fulfilledAt)
        }
    }
}
