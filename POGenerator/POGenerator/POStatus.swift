import SwiftUI

enum POStatus: String, Codable, CaseIterable, Identifiable {
    case new
    // Raw value stays "acknowledged" so POs saved before the rename still decode.
    case inProcess = "acknowledged"
    case partiallyFulfilled = "partiallyFulfilled"
    case fulfilled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .new: return "New"
        case .inProcess: return "In Process"
        case .partiallyFulfilled: return "Partially Fulfilled"
        case .fulfilled: return "Fulfilled"
        }
    }

    var systemImage: String {
        switch self {
        case .new: return "circle"
        case .inProcess: return "eye.circle.fill"
        case .partiallyFulfilled: return "circle.lefthalf.filled"
        case .fulfilled: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .new: return Theme.steel
        case .inProcess: return .yellow
        case .partiallyFulfilled: return .orange
        case .fulfilled: return .green
        }
    }

    /// Statuses that represent a delivery arriving, so they trigger the receipt
    /// request and the summary email.
    var reportsDelivery: Bool {
        self == .fulfilled || self == .partiallyFulfilled
    }
}
