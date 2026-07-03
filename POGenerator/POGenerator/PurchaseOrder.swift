import Foundation

struct PurchaseOrder: Identifiable, Hashable {
    let id: String
    let poNumber: String
    let jobNumber: String
    let customerName: String
    let sequence: Int
    let createdAt: Date
}
