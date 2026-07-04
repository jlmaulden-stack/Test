import Foundation

struct PurchaseOrder: Identifiable, Hashable, Codable {
    let id: String
    let poNumber: String
    let jobNumber: String
    let customerName: String
    let sequence: Int
    let createdAt: Date
}
