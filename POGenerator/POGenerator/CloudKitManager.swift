import CloudKit
import Foundation

enum POGeneratorError: LocalizedError {
    case iCloudUnavailable
    case tooManyConflicts

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "This device isn't signed in to iCloud. Sign in under Settings > [Your Name] so POs stay in sync with the rest of the team."
        case .tooManyConflicts:
            return "Couldn't reserve a PO number because too many people are approving POs for this job at the same time. Please try again."
        }
    }
}

extension CKError {
    /// Turns the opaque CloudKit messages into something a user can act on.
    var friendlyDescription: String {
        switch code {
        case .operationCancelled:
            return "The save was interrupted. Pull to refresh History and it will retry."
        case .networkUnavailable, .networkFailure:
            return "No network connection. Changes are saved on this device and will sync once you're back online."
        case .notAuthenticated:
            return "Not signed in to iCloud. Sign in under Settings > [Your Name]."
        case .quotaExceeded:
            return "The iCloud storage quota for this app has been exceeded."
        case .permissionFailure:
            return "iCloud rejected the change (permission denied). The container's security roles may need Write access."
        case .invalidArguments, .serverRejectedRequest:
            return "iCloud rejected the record — usually a field missing from the Production schema. \(localizedDescription)"
        default:
            return localizedDescription
        }
    }

    /// Failures that mean "try again in a moment" rather than "this won't work".
    /// These turn up routinely when operations overlap -- a tab switch re-running a
    /// fetch while a save is in flight -- because CloudKit cancels or throttles the
    /// pile-up instead of queueing it.
    var isTransient: Bool {
        switch code {
        case .operationCancelled, .requestRateLimited, .serviceUnavailable,
             .zoneBusy, .networkFailure, .networkUnavailable:
            return true
        default:
            return false
        }
    }
}

/// Syncs PO requests through the app's public CloudKit database so every employee's
/// phone sees the same requests, approvals, statuses, and receipts. Photos travel as
/// CKAssets and are cached in the local Documents directory by file name.
final class CloudKitManager {
    static let shared = CloudKitManager()

    private let container: CKContainer
    private let database: CKDatabase

    private init() {
        container = CKContainer.default()
        database = container.publicCloudDatabase
    }

    /// Runs a CloudKit operation, retrying transient failures with a short backoff
    /// before letting the error reach the UI. Without this the app surfaced a red
    /// banner for cancellations and rate limits that a manual refresh would have
    /// cleared anyway -- so this does those refreshes itself.
    private func withRetry<T>(attempts: Int = 3, _ work: () async throws -> T) async throws -> T {
        var delay: TimeInterval = 0.4
        for _ in 1 ..< max(attempts, 1) {
            do {
                return try await work()
            } catch let error as CKError where error.isTransient {
                let wait = error.retryAfterSeconds ?? delay
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                delay *= 2
            }
        }
        // Last attempt: whatever it throws is what the caller sees.
        return try await work()
    }

    func checkAccountStatus() async throws {
        let status = try await container.accountStatus()
        guard status == .available else {
            throw POGeneratorError.iCloudUnavailable
        }
    }

    // MARK: - Shared sequence counter

    private func counterRecordID(forJobNumber jobNumber: String) -> CKRecord.ID {
        let normalized = jobNumber.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return CKRecord.ID(recordName: "jobcounter-\(normalized)")
    }

    /// Atomically reserves the next PO sequence number for a job using CloudKit's
    /// optimistic-concurrency save policy with retry, so two people approving POs for
    /// the same job at the same moment never get the same sequence number.
    func reserveNextSequence(forJobNumber jobNumber: String) async throws -> Int {
        try await checkAccountStatus()

        let recordID = counterRecordID(forJobNumber: jobNumber)
        let maxAttempts = 5

        for attempt in 1...maxAttempts {
            let record: CKRecord
            do {
                record = try await withRetry { try await database.record(for: recordID) }
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "JobCounter", recordID: recordID)
                record["jobNumber"] = jobNumber
                record["count"] = Int64(0)
            }

            let nextCount = (record["count"] as? Int64 ?? 0) + 1
            record["count"] = nextCount
            record["jobNumber"] = jobNumber

            do {
                try await withRetry { try await modify(record, savePolicy: .ifServerRecordUnchanged) }
                return Int(nextCount)
            } catch let error as CKError where error.code == .serverRecordChanged {
                if attempt == maxAttempts {
                    throw POGeneratorError.tooManyConflicts
                }
                continue
            }
        }

        throw POGeneratorError.tooManyConflicts
    }

    // MARK: - PO records

    /// Upserts the full PO record (all fields and photo/receipt assets).
    func save(_ po: PurchaseOrder) async throws {
        try await checkAccountStatus()

        try await withRetry {
            let recordID = CKRecord.ID(recordName: po.id)
            let record: CKRecord
            do {
                record = try await database.record(for: recordID)
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "PurchaseOrder", recordID: recordID)
            }

            apply(po, to: record)
            try await modify(record, savePolicy: .changedKeys)
        }
    }

    /// Fetches the most recent POs across the whole team, newest first, materializing
    /// photo/receipt assets into the local Documents cache.
    func fetchHistory(limit: Int = 200) async throws -> [PurchaseOrder] {
        try await checkAccountStatus()

        let query = CKQuery(recordType: "PurchaseOrder", predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        let matchResults: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            matchResults = try await withRetry {
                try await database.records(matching: query, resultsLimit: limit).matchResults
            }
        } catch let error as CKError where error.code == .unknownItem {
            // Record type not created yet (nothing has ever been saved) -- same as empty.
            return []
        }

        return matchResults.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return purchaseOrder(from: record)
        }
    }

    /// Registers a subscription so OTHER devices get a push when a new PO request is
    /// created (CloudKit does not notify the originating device, so this pairs with
    /// the local notification fired on the requester's phone). Safe to call repeatedly.
    func subscribeToNewRequestNotifications() async {
        let subscription = CKQuerySubscription(
            recordType: "PurchaseOrder",
            predicate: NSPredicate(value: true),
            subscriptionID: "new-po-requests",
            options: .firesOnRecordCreation
        )
        let info = CKSubscription.NotificationInfo()
        info.alertBody = "New PO request awaiting approval."
        info.soundName = "default"
        subscription.notificationInfo = info

        // Ignore failures (e.g. already exists, not signed in) -- retried next launch.
        _ = try? await database.save(subscription)
    }

    // MARK: - Accounts

    /// Fetches the shared team roster so a fresh install can log into existing accounts.
    func fetchAccounts() async throws -> [Account] {
        try await checkAccountStatus()

        let query = CKQuery(recordType: "Account", predicate: NSPredicate(value: true))
        let matchResults: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            matchResults = try await withRetry {
                try await database.records(matching: query, resultsLimit: 500).matchResults
            }
        } catch let error as CKError where error.code == .unknownItem {
            // No Account record type yet -- treat as an empty roster, not a failure.
            return []
        }

        return matchResults.compactMap { _, result in
            guard let record = try? result.get(),
                  let username = record["username"] as? String, !username.isEmpty
            else { return nil }
            return Account(
                id: record.recordID.recordName,
                username: username,
                passwordHash: record["passwordHash"] as? String ?? "",
                passwordSalt: record["passwordSalt"] as? String ?? "",
                isManager: (record["isManager"] as? Int64 ?? 0) != 0
            )
        }
    }

    /// Upserts one account record (created, or password reset).
    func save(_ account: Account) async throws {
        try await checkAccountStatus()

        try await withRetry {
            let recordID = CKRecord.ID(recordName: account.id)
            let record: CKRecord
            do {
                record = try await database.record(for: recordID)
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "Account", recordID: recordID)
            }
            record["username"] = account.username
            record["passwordHash"] = account.passwordHash
            record["passwordSalt"] = account.passwordSalt
            record["isManager"] = Int64(account.isManager ? 1 : 0)
            try await modify(record, savePolicy: .changedKeys)
        }
    }

    func deleteAccount(id: String) async throws {
        try await checkAccountStatus()
        try await withRetry {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: id))
        }
    }

    // MARK: - Record mapping

    private func apply(_ po: PurchaseOrder, to record: CKRecord) {
        record["poNumber"] = po.poNumber
        record["jobNumber"] = po.jobNumber
        record["customerName"] = po.customerName
        record["sequence"] = Int64(po.sequence)
        record["createdAt"] = po.createdAt
        record["details"] = po.details
        record["createdByName"] = po.createdByName
        record["isApproved"] = Int64(po.isApproved ? 1 : 0)
        record["approvedByName"] = po.approvedByName
        record["approvedAt"] = po.approvedAt
        record["wasSelfApproved"] = Int64(po.wasSelfApproved ? 1 : 0)
        record["declinedByName"] = po.declinedByName
        record["declinedAt"] = po.declinedAt
        record["declineReason"] = po.declineReason
        record["isArchived"] = Int64(po.isArchived ? 1 : 0)
        record["archivedByName"] = po.archivedByName
        record["archivedAt"] = po.archivedAt
        record["status"] = po.status.rawValue
        record["statusUpdatedByName"] = po.statusUpdatedByName
        record["statusUpdatedAt"] = po.statusUpdatedAt
        record["fulfillmentNotes"] = po.fulfillmentNotes

        // Submission photos: parallel name/asset arrays, skipping files missing locally.
        var photoNames: [String] = []
        var photoAssets: [CKAsset] = []
        for name in po.photoFileNames where PhotoStore.fileExists(fileName: name) {
            photoNames.append(name)
            photoAssets.append(CKAsset(fileURL: PhotoStore.url(fileName: name)))
        }
        record["photoAssetNames"] = photoNames
        record["photoAssets"] = photoAssets

        // Receipts: metadata as JSON, photos as parallel key/asset arrays. A receipt can
        // hold several photos, so the key is each photo's file name rather than the
        // receipt id -- the field keeps its old name (and its [String] type) so the
        // Production schema needs no redeploy.
        if let data = try? JSONEncoder().encode(po.receipts) {
            record["receiptData"] = String(data: data, encoding: .utf8)
        }
        var receiptKeys: [String] = []
        var receiptAssets: [CKAsset] = []
        for receipt in po.receipts {
            for fileName in receipt.photoFileNames where PhotoStore.fileExists(fileName: fileName) {
                receiptKeys.append(fileName)
                receiptAssets.append(CKAsset(fileURL: PhotoStore.url(fileName: fileName)))
            }
        }
        record["receiptAssetIDs"] = receiptKeys
        record["receiptAssets"] = receiptAssets
    }

    private func purchaseOrder(from record: CKRecord) -> PurchaseOrder {
        // Materialize photo assets into the local cache under their original names.
        let photoNames = record["photoAssetNames"] as? [String] ?? []
        let photoAssets = record["photoAssets"] as? [CKAsset] ?? []
        for (name, asset) in zip(photoNames, photoAssets) {
            if let fileURL = asset.fileURL, let data = try? Data(contentsOf: fileURL) {
                PhotoStore.writeIfMissing(data, fileName: name)
            }
        }

        var receipts: [Receipt] = []
        if let json = record["receiptData"] as? String,
           let decoded = try? JSONDecoder().decode([Receipt].self, from: Data(json.utf8)) {
            receipts = decoded
        }
        // Keys are photo file names; records written by builds before multi-photo
        // receipts keyed by receipt id instead, so fall back to that receipt's photo.
        let receiptKeys = record["receiptAssetIDs"] as? [String] ?? []
        let receiptAssets = record["receiptAssets"] as? [CKAsset] ?? []
        for (key, asset) in zip(receiptKeys, receiptAssets) {
            guard let fileURL = asset.fileURL, let data = try? Data(contentsOf: fileURL) else { continue }
            if receipts.contains(where: { $0.photoFileNames.contains(key) }) {
                PhotoStore.writeIfMissing(data, fileName: key)
            } else if let legacy = receipts.first(where: { $0.id == key })?.primaryPhotoFileName {
                PhotoStore.writeIfMissing(data, fileName: legacy)
            }
        }

        return PurchaseOrder(
            id: record.recordID.recordName,
            poNumber: record["poNumber"] as? String ?? "",
            jobNumber: record["jobNumber"] as? String ?? "",
            customerName: record["customerName"] as? String ?? "",
            sequence: Int(record["sequence"] as? Int64 ?? 0),
            createdAt: record["createdAt"] as? Date ?? Date(),
            details: record["details"] as? String ?? "",
            photoFileNames: photoNames,
            createdByName: record["createdByName"] as? String ?? "",
            isApproved: (record["isApproved"] as? Int64 ?? 0) != 0,
            approvedByName: record["approvedByName"] as? String,
            approvedAt: record["approvedAt"] as? Date,
            wasSelfApproved: (record["wasSelfApproved"] as? Int64 ?? 0) != 0,
            declinedByName: record["declinedByName"] as? String,
            declinedAt: record["declinedAt"] as? Date,
            declineReason: record["declineReason"] as? String,
            isArchived: (record["isArchived"] as? Int64 ?? 0) != 0,
            archivedByName: record["archivedByName"] as? String,
            archivedAt: record["archivedAt"] as? Date,
            status: (record["status"] as? String).flatMap(POStatus.init(rawValue:)) ?? .new,
            statusUpdatedByName: record["statusUpdatedByName"] as? String,
            statusUpdatedAt: record["statusUpdatedAt"] as? Date,
            fulfillmentNotes: record["fulfillmentNotes"] as? String ?? "",
            receipts: receipts
        )
    }

    private func modify(_ record: CKRecord, savePolicy: CKModifyRecordsOperation.RecordSavePolicy) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = savePolicy
            // Without this the operation runs at default QoS, which iOS is free to
            // defer and then cancel -- surfacing as "Operation ... was cancelled"
            // rather than a real failure. These saves are user-initiated.
            operation.qualityOfService = .userInitiated
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }
}
