import Foundation

/// Manager-provisioned accounts, synced through the shared CloudKit database so every
/// device sees the same team roster: a fresh install fetches existing accounts and
/// logs into them instead of creating a new "first manager". The local UserDefaults
/// copy is an offline cache. Only managers create accounts or reset passwords — a
/// locked-out employee asks their manager, who resets it from the Account tab.
@MainActor
final class AuthStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var currentUser: Account?
    @Published var isSyncing = false
    @Published var hasSyncedOnce = false
    @Published var syncErrorMessage: String?

    private let cloud = CloudKitManager.shared
    private let defaults = UserDefaults.standard
    private let accountsKey = "AuthStore.accounts"
    private let currentUserIDKey = "AuthStore.currentUserID"

    /// Only offer "create the first manager" once a cloud check has confirmed the
    /// team really has no accounts (or the cache already has some).
    var needsSetup: Bool { accounts.isEmpty && hasSyncedOnce }

    init() {
        accounts = Self.loadAccounts(from: defaults, key: accountsKey)
        if !accounts.isEmpty {
            hasSyncedOnce = true
        }
        if let id = defaults.string(forKey: currentUserIDKey) {
            currentUser = accounts.first { $0.id == id }
        }
    }

    /// Pulls the shared roster from CloudKit, merging in local accounts that haven't
    /// reached the cloud yet. Falls back to the cache when iCloud is unreachable.
    func refreshAccounts() async {
        isSyncing = true
        syncErrorMessage = nil
        defer {
            isSyncing = false
            hasSyncedOnce = true
        }

        do {
            let remote = try await cloud.fetchAccounts()
            let remoteIDs = Set(remote.map(\.id))
            let localOnly = accounts.filter { !remoteIDs.contains($0.id) }
            accounts = remote + localOnly
            saveAccounts()
            // Keep the session pointing at the fresh copy (password may have been
            // reset remotely); drop it if the account was deleted remotely.
            if let id = currentUser?.id {
                if let refreshed = accounts.first(where: { $0.id == id }) {
                    currentUser = refreshed
                } else {
                    logOut()
                }
            }
            // Re-push local-only stragglers so both sides converge.
            for account in localOnly {
                pushToCloud(account)
            }
        } catch {
            syncErrorMessage = error.localizedDescription
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
        pushToCloud(account)
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
        pushToCloud(accounts[index])
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
        Task {
            do {
                try await cloud.deleteAccount(id: account.id)
            } catch {
                syncErrorMessage = "iCloud sync failed: \(error.localizedDescription)"
            }
        }
    }

    private func pushToCloud(_ account: Account) {
        Task {
            do {
                try await cloud.save(account)
            } catch {
                syncErrorMessage = "iCloud sync failed: \(error.localizedDescription)"
            }
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
