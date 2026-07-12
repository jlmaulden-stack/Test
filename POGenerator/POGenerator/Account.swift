import Foundation

struct Account: Identifiable, Hashable, Codable {
    let id: String
    var username: String
    var passwordHash: String
    var passwordSalt: String
    var isManager: Bool
}
