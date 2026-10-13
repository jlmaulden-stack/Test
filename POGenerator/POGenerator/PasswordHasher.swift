import CryptoKit
import Foundation

/// Salted SHA-256 hashing for locally-stored account passwords. Good enough to avoid
/// storing plaintext in UserDefaults for this local-only build; swap for a server-side
/// scheme (bcrypt/Argon2 behind real auth) once there's a backend.
enum PasswordHasher {
    static func randomSalt() -> String {
        UUID().uuidString
    }

    static func hash(password: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + password).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
