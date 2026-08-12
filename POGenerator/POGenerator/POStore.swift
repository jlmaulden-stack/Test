import CloudKit
import Foundation
import UIKit

@MainActor
final class POStore: ObservableObject {
    @Published var jobNumber: String = ""
    @Published var customerName: String = ""
    @Published var lastGenerated: PurchaseOrder?
    @Published var history: [PurchaseOrder] = []
    @Published var isGenerating = false
    @Published var isLoadingHistory = false
    @Published var errorMessage: String?

    /// Number of requests still awaiting a decision -- drives the app-icon badge.
    var pendingCount: Int {
        history.filter(\.isPending).count
    }

    private let cloud = CloudKitManager.shared
    private let defaults = UserDefaults.standard
    private let historyKey = "POStore.history"
    private let countsKey = "POStore.jobCounts"

    private var jobCounts: [String: Int] {
        get { defaults.dictionary(forKey: countsKey) as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: countsKey) }
    }

    var canRequest: Bool {
        !jobNumber.trimmingCharacters(in: .whitespaces).isEmpty
            && !customerName.trimmingCharacters(in: .whitespaces).isEmpty
            && !PONumberFormatter.jobCore(from: jobNumber).isEmpty
    }

    /// Creates a PO request. No PO number or sequence is assigned yet -- that happens
    /// only once the request is approved.
    func requestPO(details: String, photos: [UIImage], createdBy account: Account) async {
        guard canRequest else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        let trimmedJob = jobNumber.trimmingCharacters(in: .whitespaces)
        let trimmedCustomer = customerName.trimmingCharacters(in: .whitespaces)
        let photoFileNames = photos.compactMap { PhotoStore.savePhoto($0) }

        let po = PurchaseOrder(
            id: UUID().uuidString,
            poNumber: "",
            jobNumber: trimmedJob,
            customerName: trimmedCustomer,
            sequence: 0,
            createdAt: Date(),
            details: details.trimmingCharacters(in: .whitespacesAndNewlines),
            photoFileNames: photoFileNames,
            createdByName: account.username,
            isApproved: false
        )

        history.insert(po, at: 0)
        saveHistory()
        lastGenerated = po
        jobNumber = ""
        customerName = ""

        NotificationManager.notifyNewRequest(
            requester: account.username,
            customerName: trimmedCustomer,
            jobNumber: trimmedJob
        )
        updateBadge()
        pushToCloud(po)
    }

    /// Approves a pending request, assigning its sequence number and PO number now.
    /// The sequence comes from the shared CloudKit counter so approvals from different
    /// phones never collide; if iCloud is unreachable it falls back to the device-local
    /// counter and surfaces a warning.
    func approve(_ po: PurchaseOrder, by account: Account?, selfApproved: Bool) async {
        guard let index = history.firstIndex(where: { $0.id == po.id }),
              history[index].isPending
        else { return }

        let job = history[index].jobNumber
        let key = job.lowercased()

        let sequence: Int
        do {
            sequence = try await cloud.reserveNextSequence(forJobNumber: job)
        } catch {
            sequence = (jobCounts[key] ?? 0) + 1
            errorMessage = "Approved without iCloud — this PO number may not be unique across devices. \(Self.describe(error))"
        }
        jobCounts[key] = max(jobCounts[key] ?? 0, sequence)

        history[index].sequence = sequence
        history[index].poNumber = PONumberFormatter.poNumber(
            jobNumber: job,
            customerName: history[index].customerName,
            sequence: sequence
        )
        history[index].isApproved = true
        history[index].approvedByName = account?.username
        history[index].approvedAt = Date()
        history[index].wasSelfApproved = selfApproved
        syncLastGenerated(with: index)
        saveHistory()
        updateBadge()
        pushToCloud(history[index])
    }

    /// Declines a pending request with a required reason. No PO number is assigned.
    func decline(_ po: PurchaseOrder, by account: Account?, reason: String) {
        guard let index = history.firstIndex(where: { $0.id == po.id }),
              history[index].isPending
        else { return }

        history[index].declinedByName = account?.username
        history[index].declinedAt = Date()
        history[index].declineReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        syncLastGenerated(with: index)
        saveHistory()
        updateBadge()
        pushToCloud(history[index])
    }

    /// Manager-only: archives (or restores) a PO. Archiving keeps the record and its
    /// PO number intact -- deleting would leave gaps in the job's sequence -- but hides
    /// it from the main History list.
    func setArchived(_ archived: Bool, for po: PurchaseOrder, by account: Account?) {
        guard account?.isManager == true,
              let index = history.firstIndex(where: { $0.id == po.id })
        else { return }
        history[index].isArchived = archived
        history[index].archivedByName = archived ? account?.username : nil
        history[index].archivedAt = archived ? Date() : nil
        syncLastGenerated(with: index)
        saveHistory()
        pushToCloud(history[index])
    }

    /// Removes one submission photo from a PO and deletes its local file.
    func removePhoto(fileName: String, from po: PurchaseOrder) {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return }
        var names = history[index].photoFileNames
        names.removeAll { $0 == fileName }
        history[index].photoFileNames = names
        PhotoStore.delete(fileName: fileName)
        syncLastGenerated(with: index)
        saveHistory()
        pushToCloud(history[index])
    }

    func setStatus(_ status: POStatus, for po: PurchaseOrder, by account: Account?) {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return }
        history[index].status = status
        history[index].statusUpdatedByName = account?.username
        history[index].statusUpdatedAt = Date()
        if lastGenerated?.id == po.id {
            lastGenerated = history[index]
        }
        saveHistory()
        pushToCloud(history[index])
    }

    func setFulfillmentNotes(_ notes: String, for po: PurchaseOrder) {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return }
        history[index].fulfillmentNotes = notes
        if lastGenerated?.id == po.id {
            lastGenerated = history[index]
        }
        saveHistory()
        pushToCloud(history[index])
    }

    @discardableResult
    func addReceipt(_ image: UIImage, for po: PurchaseOrder) -> String? {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return nil }
        let receiptID = UUID().uuidString
        guard let fileName = PhotoStore.saveReceipt(image, id: receiptID) else { return nil }
        history[index].receipts.append(Receipt(id: receiptID, photoFileName: fileName, amount: nil))
        syncLastGenerated(with: index)
        saveHistory()
        pushToCloud(history[index])
        return receiptID
    }

    func removeReceipt(id receiptID: String, for po: PurchaseOrder) {
        guard let index = history.firstIndex(where: { $0.id == po.id }),
              let receipt = history[index].receipts.first(where: { $0.id == receiptID })
        else { return }
        removeReceipt(receipt, for: po)
    }

    func setReceiptAmount(_ amount: Double?, receiptID: String, for po: PurchaseOrder) {
        guard let poIndex = history.firstIndex(where: { $0.id == po.id }),
              let receiptIndex = history[poIndex].receipts.firstIndex(where: { $0.id == receiptID })
        else { return }
        history[poIndex].receipts[receiptIndex].amount = amount
        syncLastGenerated(with: poIndex)
        saveHistory()
        pushToCloud(history[poIndex])
    }

    func removeReceipt(_ receipt: Receipt, for po: PurchaseOrder) {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return }
        PhotoStore.delete(fileName: receipt.photoFileName)
        history[index].receipts.removeAll { $0.id == receipt.id }
        syncLastGenerated(with: index)
        saveHistory()
        pushToCloud(history[index])
    }

    /// Presents CloudKit failures in terms a user can act on.
    static func describe(_ error: Error) -> String {
        (error as? CKError)?.friendlyDescription ?? error.localizedDescription
    }

    private func syncLastGenerated(with index: Int) {
        if lastGenerated?.id == history[index].id {
            lastGenerated = history[index]
        }
    }

    private func updateBadge() {
        NotificationManager.updateBadge(count: pendingCount)
    }

    /// Uploads the PO to CloudKit in the background. Local state is already saved, so
    /// a failure just surfaces a message; the next successful push or fetch reconciles.
    private func pushToCloud(_ po: PurchaseOrder) {
        Task {
            do {
                try await cloud.save(po)
            } catch {
                errorMessage = "iCloud sync failed: \(Self.describe(error))"
            }
        }
    }

    /// Loads history from CloudKit (merging in any local records that haven't reached
    /// the cloud yet); falls back to the on-device cache when iCloud is unreachable.
    func loadHistory() async {
        isLoadingHistory = true
        errorMessage = nil
        defer { isLoadingHistory = false }

        do {
            let remote = try await cloud.fetchHistory()
            let remoteIDs = Set(remote.map(\.id))
            let localOnly = loadHistoryFromDisk().filter { !remoteIDs.contains($0.id) }
            history = (remote + localOnly).sorted { $0.createdAt > $1.createdAt }
            saveHistory()

            // Retry anything that never reached the cloud (created while iCloud was
            // unreachable or the schema was rejecting saves), so a refresh heals it.
            // Sequential on purpose: firing these concurrently makes CloudKit cancel
            // the siblings of any one that fails.
            for po in localOnly {
                do {
                    try await cloud.save(po)
                } catch {
                    errorMessage = "iCloud sync failed: \(Self.describe(error))"
                    break
                }
            }
        } catch {
            errorMessage = Self.describe(error)
            history = loadHistoryFromDisk()
        }
        updateBadge()
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: historyKey)
    }

    private func loadHistoryFromDisk() -> [PurchaseOrder] {
        guard let data = defaults.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([PurchaseOrder].self, from: data)
        else { return [] }
        return decoded
    }
}
