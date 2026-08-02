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
                record = try await database.record(for: recordID)
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "JobCounter", recordID: recordID)
                record["jobNumber"] = jobNumber
                record["count"] = Int64(0)
            }

            let nextCount = (record["count"] as? Int64 ?? 0) + 1
            record["count"] = nextCount
            record["jobNumber"] = jobNumber

            do {
                try await modify(record, savePolicy: .ifServerRecordUnchanged)
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

    /// Fetches the most recent POs across the whole team, newest first, materializing
    /// photo/receipt assets into the local Documents cache.
    func fetchHistory(limit: Int = 200) async throws -> [PurchaseOrder] {
        try await checkAccountStatus()

        let query = CKQuery(recordType: "PurchaseOrder", predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        let matchResults: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            (matchResults, _) = try await database.records(matching: query, resultsLimit: limit)
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
            (matchResults, _) = try await database.records(matching: query, resultsLimit: 500)
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

    func deleteAccount(id: String) async throws {
        try await checkAccountStatus()
        _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: id))
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

        // Receipts: metadata as JSON, photos as parallel id/asset arrays.
        if let data = try? JSONEncoder().encode(po.receipts) {
            record["receiptData"] = String(data: data, encoding: .utf8)
        }
        var receiptIDs: [String] = []
        var receiptAssets: [CKAsset] = []
        for receipt in po.receipts where PhotoStore.fileExists(fileName: receipt.photoFileName) {
            receiptIDs.append(receipt.id)
            receiptAssets.append(CKAsset(fileURL: PhotoStore.url(fileName: receipt.photoFileName)))
        }
        record["receiptAssetIDs"] = receiptIDs
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
        let receiptIDs = record["receiptAssetIDs"] as? [String] ?? []
        let receiptAssets = record["receiptAssets"] as? [CKAsset] ?? []
        for (receiptID, asset) in zip(receiptIDs, receiptAssets) {
            if let receipt = receipts.first(where: { $0.id == receiptID }),
               let fileURL = asset.fileURL,
               let data = try? Data(contentsOf: fileURL) {
                PhotoStore.writeIfMissing(data, fileName: receipt.photoFileName)
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
