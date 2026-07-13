import SwiftUI

enum POStatus: String, Codable, CaseIterable, Identifiable {
    case new
    case acknowledged
    case fulfilled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .new: return "New"
        case .acknowledged: return "Acknowledged"
        case .fulfilled: return "Fulfilled"
        }
    }

    var systemImage: String {
        switch self {
        case .new: return "circle"
        case .acknowledged: return "eye.circle.fill"
        case .fulfilled: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .new: return Theme.steel
        case .acknowledged: return .yellow
        case .fulfilled: return .green
        }
    }
}
