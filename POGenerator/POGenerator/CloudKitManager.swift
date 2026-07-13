import CloudKit
import Foundation

enum POGeneratorError: LocalizedError {
    case iCloudUnavailable
    case tooManyConflicts

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "This device isn't signed in to iCloud. Sign in under Settings > [Your Name] to generate PO numbers, so counts stay in sync with the rest of the team."
        case .tooManyConflicts:
            return "Couldn't reserve a PO number because too many people are generating one for this job at the same time. Please try again."
        }
    }
}

/// Talks to a shared (public) CloudKit database so every employee's phone sees the same
/// PO sequence count per job and the same history list, no matter which device generated it.
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

    /// Normalizes a job number into a stable CloudKit record name so the same job
    /// always maps to the same counter, regardless of stray whitespace.
    private func counterRecordID(forJobNumber jobNumber: String) -> CKRecord.ID {
        let normalized = jobNumber.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return CKRecord.ID(recordName: "jobcounter-\(normalized)")
    }

    /// Atomically reserves the next PO sequence number for a job by using CloudKit's
    /// optimistic-concurrency save policy and retrying on conflicting writes, so two
    /// employees requesting a PO for the same job at the same moment never get the
    /// same sequence number.
    private func reserveNextSequence(forJobNumber jobNumber: String) async throws -> Int {
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

            let currentCount = record["count"] as? Int64 ?? 0
            let nextCount = currentCount + 1
            record["count"] = nextCount
            record["jobNumber"] = jobNumber

            do {
                try await saveWithConflictDetection(record)
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

    /// Saves a record using the `.ifServerRecordUnchanged` policy so a stale local copy
    /// can never silently clobber a concurrent update from another device.
    private func saveWithConflictDetection(_ record: CKRecord) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = .ifServerRecordUnchanged
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

    /// Generates and persists the next PO number for a job, returning the full record
    /// so the UI can display it immediately and it also shows up in shared history.
    func generatePurchaseOrder(jobNumber: String, customerName: String) async throws -> PurchaseOrder {
        try await checkAccountStatus()

        let sequence = try await reserveNextSequence(forJobNumber: jobNumber)
        let poNumber = PONumberFormatter.poNumber(
            jobNumber: jobNumber,
            customerName: customerName,
            sequence: sequence
        )

        let record = CKRecord(recordType: "PurchaseOrder")
        record["poNumber"] = poNumber
        record["jobNumber"] = jobNumber
        record["customerName"] = customerName
        record["sequence"] = Int64(sequence)
        record["createdAt"] = Date()
        record["details"] = ""
        record["createdByName"] = ""
        record["status"] = POStatus.new.rawValue
        record["fulfillmentNotes"] = ""

        let saved = try await database.save(record)
        return PurchaseOrder(saved)
    }

    /// Fetches the most recent purchase orders across the whole team, newest first.
    func fetchHistory(limit: Int = 100) async throws -> [PurchaseOrder] {
        let query = CKQuery(recordType: "PurchaseOrder", predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        let (matchResults, _) = try await database.records(matching: query, resultsLimit: limit)
        return matchResults.compactMap { _, result in
            guard let record = try? result.get() else { return nil }
            return PurchaseOrder(record)
        }
    }
}

private extension PurchaseOrder {
    init(_ record: CKRecord) {
        self.init(
            id: record.recordID.recordName,
            poNumber: record["poNumber"] as? String ?? "",
            jobNumber: record["jobNumber"] as? String ?? "",
            customerName: record["customerName"] as? String ?? "",
            sequence: Int(record["sequence"] as? Int64 ?? 0),
            createdAt: record["createdAt"] as? Date ?? Date(),
            details: record["details"] as? String ?? "",
            photoFileNames: record["photoFileNames"] as? [String] ?? [],
            createdByName: record["createdByName"] as? String ?? "",
            status: (record["status"] as? String).flatMap(POStatus.init(rawValue:)) ?? .new,
            statusUpdatedByName: record["statusUpdatedByName"] as? String,
            statusUpdatedAt: record["statusUpdatedAt"] as? Date,
            fulfillmentNotes: record["fulfillmentNotes"] as? String ?? ""
        )
    }
}
