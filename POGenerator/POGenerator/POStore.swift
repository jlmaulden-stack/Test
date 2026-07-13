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

    private let defaults = UserDefaults.standard
    private let historyKey = "POStore.history"
    private let countsKey = "POStore.jobCounts"

    private var jobCounts: [String: Int] {
        get { defaults.dictionary(forKey: countsKey) as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: countsKey) }
    }

    var canGenerate: Bool {
        !jobNumber.trimmingCharacters(in: .whitespaces).isEmpty
            && !customerName.trimmingCharacters(in: .whitespaces).isEmpty
            && !PONumberFormatter.jobCore(from: jobNumber).isEmpty
    }

    func generate(details: String, photo: UIImage?, createdBy account: Account) async {
        guard canGenerate else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        let trimmedJob = jobNumber.trimmingCharacters(in: .whitespaces)
        let trimmedCustomer = customerName.trimmingCharacters(in: .whitespaces)
        let key = trimmedJob.lowercased()
        let sequence = (jobCounts[key] ?? 0) + 1
        let id = UUID().uuidString
        let photoFileName = photo.flatMap { PhotoStore.save($0, forPOID: id) }

        let po = PurchaseOrder(
            id: id,
            poNumber: PONumberFormatter.poNumber(jobNumber: trimmedJob, customerName: trimmedCustomer, sequence: sequence),
            jobNumber: trimmedJob,
            customerName: trimmedCustomer,
            sequence: sequence,
            createdAt: Date(),
            details: details.trimmingCharacters(in: .whitespacesAndNewlines),
            photoFileName: photoFileName,
            createdByName: account.username
        )

        jobCounts[key] = sequence
        history.insert(po, at: 0)
        saveHistory()
        lastGenerated = po
        jobNumber = ""
        customerName = ""
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

    func setAmount(_ amount: Double?, for po: PurchaseOrder) {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return }
        history[index].amount = amount
        if lastGenerated?.id == po.id {
            lastGenerated = history[index]
        }
        saveHistory()
    }

    func setReceiptPhoto(_ image: UIImage?, for po: PurchaseOrder) {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return }
        // Remove any previous receipt file before replacing or clearing.
        if let existing = history[index].receiptPhotoFileName {
            PhotoStore.delete(fileName: existing)
        }
        history[index].receiptPhotoFileName = image.flatMap { PhotoStore.saveReceipt($0, forPOID: po.id) }
        if lastGenerated?.id == po.id {
            lastGenerated = history[index]
        }
        saveHistory()
    }

    func loadHistory() async {
        isLoadingHistory = true
        errorMessage = nil
        defer { isLoadingHistory = false }
        history = loadHistoryFromDisk()
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
