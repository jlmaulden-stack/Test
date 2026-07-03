import Foundation

@MainActor
final class POStore: ObservableObject {
    @Published var jobNumber: String = ""
    @Published var customerName: String = ""
    @Published var lastGenerated: PurchaseOrder?
    @Published var history: [PurchaseOrder] = []
    @Published var isGenerating = false
    @Published var isLoadingHistory = false
    @Published var errorMessage: String?

    private let cloudKit = CloudKitManager.shared

    var canGenerate: Bool {
        !jobNumber.trimmingCharacters(in: .whitespaces).isEmpty
            && !customerName.trimmingCharacters(in: .whitespaces).isEmpty
            && !PONumberFormatter.jobCore(from: jobNumber).isEmpty
    }

    func generate() async {
        guard canGenerate else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }

        do {
            let po = try await cloudKit.generatePurchaseOrder(
                jobNumber: jobNumber.trimmingCharacters(in: .whitespaces),
                customerName: customerName.trimmingCharacters(in: .whitespaces)
            )
            lastGenerated = po
            history.insert(po, at: 0)
            jobNumber = ""
            customerName = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadHistory() async {
        isLoadingHistory = true
        errorMessage = nil
        defer { isLoadingHistory = false }

        do {
            history = try await cloudKit.fetchHistory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
