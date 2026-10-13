import Foundation

enum HistorySort: String, CaseIterable, Identifiable {
    case dateNewest
    case jobNumber
    case customerName

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateNewest: return "Date (Newest)"
        case .jobNumber: return "Job Number"
        case .customerName: return "Customer Name"
        }
    }

    var systemImage: String {
        switch self {
        case .dateNewest: return "calendar"
        case .jobNumber: return "number"
        case .customerName: return "person"
        }
    }

    /// Ordering applied to the (already search-filtered) history list.
    func sorted(_ orders: [PurchaseOrder]) -> [PurchaseOrder] {
        switch self {
        case .dateNewest:
            return orders.sorted { $0.createdAt > $1.createdAt }
        case .jobNumber:
            return orders.sorted {
                $0.jobNumber.localizedStandardCompare($1.jobNumber) == .orderedAscending
            }
        case .customerName:
            return orders.sorted {
                $0.customerName.localizedCaseInsensitiveCompare($1.customerName) == .orderedAscending
            }
        }
    }
}
