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
    }

    /// Approves a pending request, assigning its sequence number and PO number now.
    func approve(_ po: PurchaseOrder, by account: Account?, selfApproved: Bool) {
        guard let index = history.firstIndex(where: { $0.id == po.id }),
              history[index].isPending
        else { return }

        let job = history[index].jobNumber
        let key = job.lowercased()
        let sequence = (jobCounts[key] ?? 0) + 1
        jobCounts[key] = sequence

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
    }

    func setFulfillmentNotes(_ notes: String, for po: PurchaseOrder) {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return }
        history[index].fulfillmentNotes = notes
        if lastGenerated?.id == po.id {
            lastGenerated = history[index]
        }
        saveHistory()
    }

    @discardableResult
    func addReceipt(_ image: UIImage, for po: PurchaseOrder) -> String? {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return nil }
        let receiptID = UUID().uuidString
        guard let fileName = PhotoStore.saveReceipt(image, id: receiptID) else { return nil }
        history[index].receipts.append(Receipt(id: receiptID, photoFileName: fileName, amount: nil))
        syncLastGenerated(with: index)
        saveHistory()
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
    }

    func removeReceipt(_ receipt: Receipt, for po: PurchaseOrder) {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return }
        PhotoStore.delete(fileName: receipt.photoFileName)
        history[index].receipts.removeAll { $0.id == receipt.id }
        syncLastGenerated(with: index)
        saveHistory()
    }

    private func syncLastGenerated(with index: Int) {
        if lastGenerated?.id == history[index].id {
            lastGenerated = history[index]
        }
    }

    private func updateBadge() {
        NotificationManager.updateBadge(count: pendingCount)
    }

    func loadHistory() async {
        isLoadingHistory = true
        errorMessage = nil
        defer { isLoadingHistory = false }
        history = loadHistoryFromDisk()
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
