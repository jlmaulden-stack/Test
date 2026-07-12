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

    func generate(details: String, photo: UIImage?, createdBy employee: Employee) async {
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
            createdByName: employee.name,
            createdByPhone: employee.phoneNumber,
            isFulfilled: false,
            fulfilledByName: nil,
            fulfilledAt: nil
        )

        jobCounts[key] = sequence
        history.insert(po, at: 0)
        saveHistory()
        lastGenerated = po
        jobNumber = ""
        customerName = ""
    }

    func setFulfilled(_ fulfilled: Bool, for po: PurchaseOrder, by employee: Employee?) {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return }
        history[index].isFulfilled = fulfilled
        history[index].fulfilledByName = fulfilled ? employee?.name : nil
        history[index].fulfilledAt = fulfilled ? Date() : nil
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
