import Foundation

/// Manager-provisioned accounts, stored locally. The first account created on a fresh
/// install becomes a manager; only managers can create further accounts or reset
/// passwords. There's no self-service password reset — a locked-out employee asks
/// their manager, who resets it from the Account tab.
@MainActor
final class AuthStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var currentUser: Account?

    private let defaults = UserDefaults.standard
    private let accountsKey = "AuthStore.accounts"
    private let currentUserIDKey = "AuthStore.currentUserID"

    var needsSetup: Bool { accounts.isEmpty }

    init() {
        accounts = Self.loadAccounts(from: defaults, key: accountsKey)
        if let id = defaults.string(forKey: currentUserIDKey) {
            currentUser = accounts.first { $0.id == id }
        }
    }

    /// Creates the very first account (a manager) when no accounts exist yet.
    @discardableResult
    func createInitialManagerAccount(username: String, password: String) -> Bool {
        guard accounts.isEmpty else { return false }
        return createAccount(username: username, password: password, isManager: true, requestedBy: nil)
    }

    /// Only a manager may create new accounts once the roster is non-empty.
    @discardableResult
    func createAccount(username: String, password: String, isManager: Bool, requestedBy manager: Account?) -> Bool {
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        guard !trimmedUsername.isEmpty, !password.isEmpty else { return false }
        guard !accounts.contains(where: { $0.username.caseInsensitiveCompare(trimmedUsername) == .orderedSame }) else {
            return false
        }
        if !accounts.isEmpty {
            guard manager?.isManager == true else { return false }
        }

        let salt = PasswordHasher.randomSalt()
        let account = Account(
            id: UUID().uuidString,
            username: trimmedUsername,
            passwordHash: PasswordHasher.hash(password: password, salt: salt),
            passwordSalt: salt,
            isManager: isManager
        )
        accounts.append(account)
        saveAccounts()
        return true
    }

    func logIn(username: String, password: String) -> Bool {
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        guard let account = accounts.first(where: { $0.username.caseInsensitiveCompare(trimmedUsername) == .orderedSame }),
              PasswordHasher.hash(password: password, salt: account.passwordSalt) == account.passwordHash
        else {
            return false
        }
        currentUser = account
        defaults.set(account.id, forKey: currentUserIDKey)
        return true
    }

    func logOut() {
        currentUser = nil
        defaults.removeObject(forKey: currentUserIDKey)
    }

    /// Manager-only: resets another account's password after an out-of-app request.
    @discardableResult
    func resetPassword(for account: Account, newPassword: String, requestedBy manager: Account?) -> Bool {
        guard manager?.isManager == true, !newPassword.isEmpty else { return false }
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return false }

        let salt = PasswordHasher.randomSalt()
        accounts[index].passwordSalt = salt
        accounts[index].passwordHash = PasswordHasher.hash(password: newPassword, salt: salt)
        saveAccounts()
        if currentUser?.id == account.id {
            currentUser = accounts[index]
        }
        return true
    }

    func removeAccount(_ account: Account, requestedBy manager: Account?) {
        guard manager?.isManager == true else { return }
        // Never delete the last manager, or no one could manage accounts again.
        if account.isManager && accounts.filter(\.isManager).count == 1 { return }
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
        if currentUser?.id == account.id {
            logOut()
        }
    }

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: accountsKey)
    }

    private static func loadAccounts(from defaults: UserDefaults, key: String) -> [Account] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Account].self, from: data)
        else { return [] }
        return decoded
    }
}
