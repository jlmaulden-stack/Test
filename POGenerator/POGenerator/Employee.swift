import Foundation

struct Employee: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var phoneNumber: String
}
