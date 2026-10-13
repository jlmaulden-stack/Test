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

    /// Bumped when photos land on disk, so views redraw and pick them up.
    @Published var photoCacheVersion = 0
    /// POs whose photos are downloading right now.
    @Published var downloadingPhotoPOIDs: Set<String> = []

    /// Show the cached history immediately instead of an empty screen while CloudKit
    /// answers. The refresh that follows reconciles it.
    init() {
        history = loadHistoryFromDisk().sorted { $0.createdAt > $1.createdAt }
        updateBadge()
    }

    /// Number of requests still awaiting a decision -- drives the app-icon badge.
    var pendingCount: Int {
        history.filter(\.isPending).count
    }

    private let cloud = CloudKitManager.shared

    /// The history load currently in flight, if any. `.task` re-fires on tab switches
    /// and navigation returns, and can overlap pull-to-refresh -- each one used to
    /// start its own CloudKit query and saves, which CloudKit then cancelled as a
    /// pile-up. Now every caller awaits the same load.
    private var historyLoad: Task<Void, Never>?

    /// Tail of the queue of cloud writes. Saves run one at a time for the same reason:
    /// two status changes in a row, or a push landing mid-refresh, used to cancel each
    /// other out and surface "the save was interrupted".
    private var cloudWrites: Task<Void, Never>?

    /// Pending debounced pushes, keyed by PO and field, plus the POs they belong to.
    private var debouncedPushes: [String: Task<Void, Never>] = [:]
    private var pendingEditPOIDs: Set<String> = []

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

    /// Edits the material list. Allowed at any point in the PO's life -- what's needed
    /// on a job changes after the request goes in.
    func setDetails(_ details: String, for po: PurchaseOrder) {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return }
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard history[index].details != trimmed else { return }
        history[index].details = trimmed
        syncLastGenerated(with: index)
        saveHistory()
        pushToCloudDebounced(poID: po.id, field: "details")
    }

    /// Adds a submission photo to an existing PO, so photos can be attached as the job
    /// progresses rather than only at request time.
    @discardableResult
    func addPhoto(_ image: UIImage, to po: PurchaseOrder) -> String? {
        guard let index = history.firstIndex(where: { $0.id == po.id }),
              let fileName = PhotoStore.savePhoto(image)
        else { return nil }
        history[index].photoFileNames.append(fileName)
        syncLastGenerated(with: index)
        saveHistory()
        pushToCloud(history[index])
        return fileName
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
        guard let index = history.firstIndex(where: { $0.id == po.id }),
              history[index].fulfillmentNotes != notes
        else { return }
        history[index].fulfillmentNotes = notes
        syncLastGenerated(with: index)
        saveHistory()
        pushToCloudDebounced(poID: po.id, field: "notes")
    }

    @discardableResult
    func addReceipt(_ image: UIImage, for po: PurchaseOrder) -> String? {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return nil }
        let receiptID = UUID().uuidString
        guard let fileName = PhotoStore.saveReceiptPhoto(image, receiptID: receiptID) else { return nil }
        history[index].receipts.append(Receipt(id: receiptID, photoFileName: fileName, amount: nil))
        syncLastGenerated(with: index)
        saveHistory()
        pushToCloud(history[index])
        return receiptID
    }

    /// Adds another photo to an existing receipt -- a long receipt, or a multi-page
    /// invoice from a partial delivery, takes more than one shot. The amount already
    /// recorded on the receipt covers them all.
    @discardableResult
    func addReceiptPhoto(_ image: UIImage, toReceipt receiptID: String, for po: PurchaseOrder) -> String? {
        guard let poIndex = history.firstIndex(where: { $0.id == po.id }),
              let receiptIndex = history[poIndex].receipts.firstIndex(where: { $0.id == receiptID }),
              let fileName = PhotoStore.saveReceiptPhoto(image, receiptID: receiptID)
        else { return nil }
        history[poIndex].receipts[receiptIndex].photoFileNames.append(fileName)
        syncLastGenerated(with: poIndex)
        saveHistory()
        pushToCloud(history[poIndex])
        return fileName
    }

    /// Removes one photo from a receipt. Taking away the last photo removes the receipt
    /// along with its amount -- an amount with nothing backing it isn't a receipt.
    func removeReceiptPhoto(fileName: String, fromReceipt receiptID: String, for po: PurchaseOrder) {
        guard let poIndex = history.firstIndex(where: { $0.id == po.id }),
              let receiptIndex = history[poIndex].receipts.firstIndex(where: { $0.id == receiptID })
        else { return }

        var names = history[poIndex].receipts[receiptIndex].photoFileNames
        names.removeAll { $0 == fileName }
        PhotoStore.delete(fileName: fileName)

        if names.isEmpty {
            history[poIndex].receipts.remove(at: receiptIndex)
        } else {
            history[poIndex].receipts[receiptIndex].photoFileNames = names
        }
        syncLastGenerated(with: poIndex)
        saveHistory()
        pushToCloud(history[poIndex])
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
        guard history[poIndex].receipts[receiptIndex].amount != amount else { return }
        history[poIndex].receipts[receiptIndex].amount = amount
        syncLastGenerated(with: poIndex)
        saveHistory()
        pushToCloudDebounced(poID: po.id, field: "amount-\(receiptID)")
    }

    func removeReceipt(_ receipt: Receipt, for po: PurchaseOrder) {
        guard let index = history.firstIndex(where: { $0.id == po.id }) else { return }
        for fileName in receipt.photoFileNames {
            PhotoStore.delete(fileName: fileName)
        }
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
        let previous = cloudWrites
        cloudWrites = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.cloud.save(po)
            } catch {
                self.errorMessage = "iCloud sync failed: \(Self.describe(error))"
            }
        }
    }

    /// Downloads one PO's photos if any are missing from this device. History fetches
    /// metadata only, so this runs when a PO is opened. Local state is left alone --
    /// only the image files land -- so an edit that hasn't synced yet can't be clobbered.
    func ensurePhotos(for po: PurchaseOrder) async {
        let expected = po.photoFileNames + po.receipts.flatMap(\.photoFileNames)
        let missing = expected.filter { !PhotoStore.fileExists(fileName: $0) }
        guard !missing.isEmpty, !downloadingPhotoPOIDs.contains(po.id) else { return }

        downloadingPhotoPOIDs.insert(po.id)
        defer { downloadingPhotoPOIDs.remove(po.id) }
        do {
            try await cloud.downloadPhotos(for: po.id)
            photoCacheVersion += 1
        } catch {
            errorMessage = "Couldn't download photos: \(Self.describe(error))"
        }
    }

    /// Downloads receipt photos for every PO that has receipts -- used before a bulk
    /// export, which would otherwise quietly skip receipts this device never cached.
    func ensureReceiptPhotos(for orders: [PurchaseOrder]) async {
        for po in orders where !po.receipts.isEmpty {
            await ensurePhotos(for: po)
        }
    }

    /// Queues a cloud push for a field being typed into. The edit is already saved on
    /// device; the upload waits for a pause so one sentence isn't dozens of CloudKit
    /// saves fighting each other.
    private func pushToCloudDebounced(poID: String, field: String) {
        let handle = "\(poID)-\(field)"
        pendingEditPOIDs.insert(poID)
        debouncedPushes[handle]?.cancel()
        debouncedPushes[handle] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.debouncedPushes[handle] = nil
            // Push the current version, not the one captured when typing started. A
            // push writes the whole record, so it covers every pending field at once.
            self.pendingEditPOIDs.remove(poID)
            if let po = self.history.first(where: { $0.id == poID }) {
                self.pushToCloud(po)
            }
        }
    }

    /// Sends debounced text edits immediately. Called when leaving the detail page or
    /// backgrounding the app, so a pause shorter than the debounce can't strand an edit
    /// on one device.
    func flushPendingPushes() {
        guard !pendingEditPOIDs.isEmpty else { return }
        for task in debouncedPushes.values {
            task.cancel()
        }
        debouncedPushes.removeAll()
        let ids = pendingEditPOIDs
        pendingEditPOIDs.removeAll()
        for po in history where ids.contains(po.id) {
            pushToCloud(po)
        }
    }

    /// Loads history from CloudKit (merging in any local records that haven't reached
    /// the cloud yet); falls back to the on-device cache when iCloud is unreachable.
    func loadHistory() async {
        // Join the load already running rather than racing it.
        if let inFlight = historyLoad {
            await inFlight.value
            return
        }
        let load = Task { await performHistoryLoad() }
        historyLoad = load
        await load.value
        historyLoad = nil
    }

    private func performHistoryLoad() async {
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
            // Queued rather than awaited: the list is already up to date, so there's
            // no reason to hold the spinner while the stragglers upload one by one.
            for po in localOnly {
                pushToCloud(po)
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
