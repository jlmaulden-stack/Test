import CloudKit
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

    /// The roster refresh currently in flight. Login and the Account tab both refresh
    /// on appear, so without this they race each other into CloudKit and one gets
    /// cancelled.
    private var refresh: Task<Void, Never>?

    /// Tail of the queue of account saves, so they upload one at a time.
    private var cloudWrites: Task<Void, Never>?

    private let defaults = UserDefaults.standard
    private let accountsKey = "AuthStore.accounts"
    private let currentUserIDKey = "AuthStore.currentUserID"
    private let knownRemoteIDsKey = "AuthStore.knownRemoteIDs"
    private let pendingDeletionsKey = "AuthStore.pendingDeletions"

    /// Accounts this device has seen in the cloud at least once. An account in this set
    /// that is missing from a later fetch was deleted by a manager -- without it, the
    /// merge in refreshAccounts treated the local copy as "not uploaded yet" and pushed
    /// it straight back, so deleted users could keep logging in.
    private var knownRemoteIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: knownRemoteIDsKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: knownRemoteIDsKey) }
    }

    /// Deletions that haven't been confirmed by CloudKit yet (offline, or the delete
    /// failed). Retried on every refresh, and filtered out of fetches meanwhile.
    private var pendingDeletions: Set<String> {
        get { Set(defaults.stringArray(forKey: pendingDeletionsKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: pendingDeletionsKey) }
    }

    /// Only offer "create the first manager" once a cloud check has confirmed the
    /// team really has no accounts (or the cache already has some).
    var needsSetup: Bool { accounts.isEmpty && hasSyncedOnce }

    /// Usernames held by more than one account. Two devices can each set up a "first
    /// manager" before either has synced; the roster then carries both, with separate
    /// passwords. Flagged in the Team list so a manager can delete the spare.
    var duplicateUsernames: Set<String> {
        var counts: [String: Int] = [:]
        for account in accounts {
            counts[account.username.lowercased(), default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    func isDuplicate(_ account: Account) -> Bool {
        duplicateUsernames.contains(account.username.lowercased())
    }

    init() {
        accounts = Self.loadAccounts(from: defaults, key: accountsKey)
        if !accounts.isEmpty {
            hasSyncedOnce = true
        }
        // First run after this build: everything already cached came from the cloud, so
        // seed the set. Without this, the first refresh would treat a stale account as
        // "never uploaded" and push it back one last time.
        if defaults.object(forKey: knownRemoteIDsKey) == nil {
            defaults.set(accounts.map(\.id), forKey: knownRemoteIDsKey)
        }
        if let id = defaults.string(forKey: currentUserIDKey) {
            currentUser = accounts.first { $0.id == id }
        }
    }

    /// Pulls the shared roster from CloudKit, merging in local accounts that haven't
    /// reached the cloud yet. Falls back to the cache when iCloud is unreachable.
    func refreshAccounts() async {
        if let inFlight = refresh {
            await inFlight.value
            return
        }
        let task = Task { await performRefresh() }
        refresh = task
        await task.value
        refresh = nil
    }

    private func performRefresh() async {
        isSyncing = true
        syncErrorMessage = nil
        defer {
            isSyncing = false
            hasSyncedOnce = true
        }

        do {
            await retryPendingDeletions()

            let fetched = try await cloud.fetchAccounts()
            // A delete that hasn't been confirmed yet still shows up in the fetch.
            let stillPending = pendingDeletions
            let remote = fetched.filter { !stillPending.contains($0.id) }
            let remoteIDs = Set(remote.map(\.id))

            // An empty roster can't be real while this device holds accounts -- the last
            // manager can't be deleted -- so it means the records never made it up (a
            // brand new container, or saves that were failing). Re-upload rather than
            // wiping everyone out.
            if remote.isEmpty && !accounts.isEmpty {
                for account in accounts {
                    pushToCloud(account)
                }
                return
            }

            // Only accounts that have NEVER reached the cloud are stragglers to push.
            // One that was there and is gone now was deleted, so it goes.
            let seen = knownRemoteIDs
            let localOnly = accounts.filter { !remoteIDs.contains($0.id) && !seen.contains($0.id) }
            accounts = remote + localOnly
            knownRemoteIDs = seen.union(remoteIDs)
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
            syncErrorMessage = Self.describe(error)
        }
    }

    /// Re-sends deletes that never reached CloudKit. A delete that only happened on one
    /// device would otherwise come back on the next fetch.
    private func retryPendingDeletions() async {
        for id in pendingDeletions {
            do {
                try await cloud.deleteAccount(id: id)
                pendingDeletions.remove(id)
                knownRemoteIDs.remove(id)
            } catch let error as CKError where error.code == .unknownItem {
                // Already gone -- that's the outcome we wanted.
                pendingDeletions.remove(id)
                knownRemoteIDs.remove(id)
            } catch {
                // Leave it queued; the next refresh tries again.
            }
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
        // Check every account with this username, not just the first: duplicates can
        // exist (two devices both set up a first manager before syncing), and each one
        // has its own password. Whichever password was typed picks the account.
        let candidates = accounts.filter {
            $0.username.caseInsensitiveCompare(trimmedUsername) == .orderedSame
        }
        guard let account = candidates.first(where: {
            PasswordHasher.hash(password: password, salt: $0.passwordSalt) == $0.passwordHash
        }) else {
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
        // Queue the deletion before attempting it, so a failure (or a quit mid-flight)
        // leaves something to retry instead of letting the account come back.
        pendingDeletions.insert(account.id)
        Task {
            await retryPendingDeletions()
            if pendingDeletions.contains(account.id) {
                syncErrorMessage = "\(account.username) was removed on this device but iCloud hasn't confirmed it yet. It will retry automatically."
            }
        }
    }

    /// Presents CloudKit failures in terms a user can act on.
    static func describe(_ error: Error) -> String {
        (error as? CKError)?.friendlyDescription ?? error.localizedDescription
    }

    private func pushToCloud(_ account: Account) {
        let previous = cloudWrites
        cloudWrites = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.cloud.save(account)
                // It's in the cloud now, so a later fetch that doesn't list it means a
                // manager deleted it -- not that it still needs uploading.
                self.knownRemoteIDs.insert(account.id)
            } catch {
                self.syncErrorMessage = "iCloud sync failed: \(Self.describe(error))"
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
