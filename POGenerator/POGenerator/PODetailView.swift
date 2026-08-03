import SwiftUI
import PhotosUI
import UIKit

struct PODetailView: View {
    @EnvironmentObject private var store: POStore
    @EnvironmentObject private var authStore: AuthStore
    let po: PurchaseOrder

    @State private var notesText: String = ""
    @State private var showReceiptOptions = false
    @State private var showCameraCapture = false
    @State private var showPhotoLibraryPicker = false
    @State private var receiptPickerItems: [PhotosPickerItem] = []
    @State private var exportPayload: ExportPayload?
    // Set when the user chose "Add Receipt Photo" from the fulfilled prompt, so the
    // status flips to Fulfilled once a receipt is actually added.
    @State private var fulfillAfterReceipt = false
    // Receipts awaiting a required dollar amount, prompted one at a time as uploaded.
    @State private var pendingAmountReceiptIDs: [String] = []
    @State private var amountPromptText = ""
    // Single alert slot: SwiftUI only honors one .alert per view, so both prompts
    // share this one. Two stacked .alert modifiers silently dropped one of them.
    @State private var activePrompt: ActivePrompt?

    private enum ActivePrompt: Identifiable {
        case fulfillWithoutReceipt
        case receiptAmount(receiptID: String)

        var id: String {
            switch self {
            case .fulfillWithoutReceipt: return "fulfill"
            case .receiptAmount(let receiptID): return "amount-\(receiptID)"
            }
        }
    }

    private var current: PurchaseOrder {
        store.history.first(where: { $0.id == po.id }) ?? po
    }

    /// Camera capture adds a receipt on set; a computed binding avoids an onChange on
    /// UIImage, which isn't Equatable.
    private var cameraBinding: Binding<UIImage?> {
        Binding(get: { nil }, set: { image in
            if let image, let receiptID = store.addReceipt(image, for: current) {
                pendingAmountReceiptIDs.append(receiptID)
                applyPendingFulfillmentIfNeeded()
                scheduleNextAmountPrompt()
            }
        })
    }

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    private var statusBinding: Binding<POStatus> {
        Binding(
            get: { current.status },
            set: { newStatus in
                // Nudge the user to attach a receipt before marking fulfilled, but let
                // them bypass it.
                if newStatus == .fulfilled && current.receipts.isEmpty {
                    // Defer so the Picker's pushed selection screen finishes popping;
                    // presenting mid-transition swallows the alert.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        activePrompt = .fulfillWithoutReceipt
                    }
                } else {
                    store.setStatus(newStatus, for: current, by: authStore.currentUser)
                }
            }
        )
    }

    var body: some View {
        Form {
            if current.isApproved {
                Section("PO Number") {
                    Text(current.poNumber)
                        .font(.system(.title2, design: .monospaced))
                        .bold()
                        .foregroundColor(Theme.accent)
                    if let approver = current.approvedByName {
                        LabeledContent("Approved By", value: current.wasSelfApproved ? "\(approver) (self)" : approver)
                    }
                }
                .listRowBackground(Theme.panel)
            } else if current.isDeclined {
                Section("Declined") {
                    Label("Request Declined", systemImage: "xmark.seal")
                        .foregroundColor(.red)
                    if let reason = current.declineReason, !reason.isEmpty {
                        LabeledContent("Reason", value: reason)
                    }
                    if let by = current.declinedByName {
                        LabeledContent("Declined By", value: by)
                    }
                    if let at = current.declinedAt {
                        LabeledContent("Declined At", value: at.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .listRowBackground(Theme.panel)
            } else {
                Section("Approval") {
                    Label("Pending Approval", systemImage: "clock.badge.questionmark")
                        .foregroundColor(.orange)
                    Text("A PO number is assigned once this request is approved. Only managers can approve.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    ApprovalControls(po: current)
                }
                .listRowBackground(Theme.panel)
            }

            Section("Job") {
                LabeledContent("Job Number", value: current.jobNumber)
                LabeledContent("Customer", value: current.customerName)
                LabeledContent("Created By", value: current.createdByName)
                LabeledContent("Created", value: current.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            .listRowBackground(Theme.panel)

            if !current.details.isEmpty {
                Section("Description") {
                    Text(current.details)
                }
                .listRowBackground(Theme.panel)
            }

            if !current.photoFileNames.isEmpty {
                Section("Photos") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(current.photoFileNames, id: \.self) { fileName in
                                if let image = PhotoStore.loadImage(fileName: fileName) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 120, height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listRowBackground(Theme.panel)
            }

            if current.isApproved {
                Section("Status") {
                    Picker("Status", selection: statusBinding) {
                        ForEach(POStatus.allCases) { status in
                            Label(status.label, systemImage: status.systemImage).tag(status)
                        }
                    }
                    .tint(current.status.color)

                    if let updatedBy = current.statusUpdatedByName {
                        LabeledContent("Updated By", value: updatedBy)
                    }
                    if let updatedAt = current.statusUpdatedAt {
                        LabeledContent("Updated At", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .listRowBackground(Theme.panel)

                Section("Fulfillment Notes") {
                    TextField("Add notes about fulfillment...", text: $notesText, axis: .vertical)
                        .lineLimit(3...8)
                }
                .listRowBackground(Theme.panel)

                receiptsSection
            }
        }
        .industrialForm()
        .navigationTitle("PO DETAILS")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            notesText = current.fulfillmentNotes
        }
        .onChange(of: notesText) { newValue in
            store.setFulfillmentNotes(newValue, for: current)
        }
        .confirmationDialog("Add Receipt", isPresented: $showReceiptOptions) {
            if cameraAvailable {
                Button("Take Photo") { showCameraCapture = true }
            }
            Button("Choose from Library") { showPhotoLibraryPicker = true }
        }
        .photosPicker(isPresented: $showPhotoLibraryPicker, selection: $receiptPickerItems, matching: .images)
        .onChange(of: receiptPickerItems) { newItems in
            guard !newItems.isEmpty else { return }
            Task {
                var addedAny = false
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data),
                       let receiptID = store.addReceipt(image, for: current) {
                        pendingAmountReceiptIDs.append(receiptID)
                        addedAny = true
                    }
                }
                receiptPickerItems = []
                if addedAny {
                    applyPendingFulfillmentIfNeeded()
                    scheduleNextAmountPrompt()
                }
            }
        }
        .fullScreenCover(isPresented: $showCameraCapture) {
            CameraCaptureView(image: cameraBinding)
                .ignoresSafeArea()
        }
        .sheet(item: $exportPayload) { payload in
            ShareSheet(items: payload.urls)
        }
        .alert(promptTitle, isPresented: promptPresented, presenting: activePrompt) { prompt in
            switch prompt {
            case .fulfillWithoutReceipt:
                Button("Add Receipt Photo") {
                    fulfillAfterReceipt = true
                    // Defer so the alert finishes dismissing before the dialog presents.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showReceiptOptions = true
                    }
                }
                Button("Mark Fulfilled Anyway") {
                    store.setStatus(.fulfilled, for: current, by: authStore.currentUser)
                }
                Button("Cancel", role: .cancel) {}

            case .receiptAmount(let receiptID):
                TextField("0.00", text: $amountPromptText)
                    .keyboardType(.decimalPad)
                Button("Save") {
                    if let amount = parseAmount(amountPromptText), amount > 0 {
                        store.setReceiptAmount(amount, receiptID: receiptID, for: current)
                    } else {
                        // A dollar amount is required, so discard a receipt left without one.
                        store.removeReceipt(id: receiptID, for: current)
                    }
                    finishAmountPrompt()
                }
                Button("Cancel", role: .cancel) {
                    store.removeReceipt(id: receiptID, for: current)
                    finishAmountPrompt()
                }
            }
        } message: { prompt in
            switch prompt {
            case .fulfillWithoutReceipt:
                Text("Marking this PO fulfilled usually includes a receipt photo. Add one now, or mark it fulfilled anyway.")
            case .receiptAmount:
                Text("A dollar amount is required for each receipt. Cancelling discards this receipt photo.")
            }
        }
    }

    private var promptTitle: String {
        if case .receiptAmount = activePrompt { return "Enter Receipt Amount" }
        return "Add a Receipt?"
    }

    private var promptPresented: Binding<Bool> {
        Binding(get: { activePrompt != nil }, set: { if !$0 { activePrompt = nil } })
    }

    /// After a receipt is added as part of the "mark fulfilled" flow, complete the
    /// status change.
    private func applyPendingFulfillmentIfNeeded() {
        guard fulfillAfterReceipt else { return }
        fulfillAfterReceipt = false
        store.setStatus(.fulfilled, for: current, by: authStore.currentUser)
    }

    /// Shows the amount prompt for the next just-uploaded receipt, after a short delay
    /// so any dismissing camera/library/alert presentation clears first.
    private func scheduleNextAmountPrompt() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard activePrompt == nil, !pendingAmountReceiptIDs.isEmpty else { return }
            let next = pendingAmountReceiptIDs.removeFirst()
            amountPromptText = ""
            activePrompt = .receiptAmount(receiptID: next)
        }
    }

    private func finishAmountPrompt() {
        activePrompt = nil
        scheduleNextAmountPrompt()
    }

    private func parseAmount(_ text: String) -> Double? {
        let cleaned = text.filter { $0.isNumber || $0 == "." }
        return cleaned.isEmpty ? nil : Double(cleaned)
    }

    @ViewBuilder
    private var receiptsSection: some View {
        Section {
            ForEach(current.receipts) { receipt in
                ReceiptRow(po: current, receipt: receipt)
            }

            Button {
                fulfillAfterReceipt = false
                showReceiptOptions = true
            } label: {
                Label("Add Receipt Photo", systemImage: "doc.viewfinder")
            }

            if !current.receipts.isEmpty {
                Button {
                    let urls = ReceiptExporter.exportURLs(for: current)
                    if !urls.isEmpty {
                        exportPayload = ExportPayload(urls: urls)
                    }
                } label: {
                    Label("Export Receipts", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            HStack {
                Text("Receipts")
                Spacer()
                if let total = current.totalAmount {
                    Text("Total \(total, format: .currency(code: "USD"))")
                }
            }
        }
        .listRowBackground(Theme.panel)
    }
}

/// One receipt: photo, its own dollar-amount field, and a remove button. Owns its
/// amount text state so typing (e.g. a trailing ".") isn't reformatted mid-entry.
private struct ReceiptRow: View {
    @EnvironmentObject private var store: POStore
    let po: PurchaseOrder
    let receipt: Receipt
    @State private var amountText: String = ""
    @State private var showDeleteConfirmation = false
    @FocusState private var amountFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = PhotoStore.loadImage(fileName: receipt.photoFileName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Text("$")
                    .foregroundColor(.secondary)
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
                    .focused($amountFocused)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            amountText = receipt.amount.map { String(format: "%.2f", $0) } ?? ""
        }
        .onChange(of: amountText) { newValue in
            // Force a valid currency entry: digits with at most one decimal point and
            // two fractional digits.
            let cleaned = sanitizeCurrency(newValue)
            if cleaned != newValue {
                amountText = cleaned
                return
            }
            store.setReceiptAmount(cleaned.isEmpty ? nil : Double(cleaned), receiptID: receipt.id, for: po)
        }
        .onChange(of: amountFocused) { focused in
            // Normalize to two decimals once the user leaves the field.
            if !focused, let value = Double(amountText) {
                amountText = String(format: "%.2f", value)
            }
        }
        .confirmationDialog(
            "Delete this receipt photo?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Receipt", role: .destructive) {
                store.removeReceipt(receipt, for: po)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Keeps only digits and at most one decimal point with up to two fractional digits.
    private func sanitizeCurrency(_ text: String) -> String {
        var result = ""
        var hasDot = false
        var decimals = 0
        for ch in text {
            if ch.isNumber {
                if hasDot {
                    guard decimals < 2 else { continue }
                    decimals += 1
                }
                result.append(ch)
            } else if ch == "." && !hasDot {
                hasDot = true
                result.append(ch)
            }
        }
        return result
    }
}

#Preview {
    NavigationStack {
        PODetailView(po: PurchaseOrder(
            id: "1",
            poNumber: "0234-1-ACME",
            jobNumber: "4521-10234",
            customerName: "Acme Corp",
            sequence: 1,
            createdAt: Date(),
            details: "2x 4x8 plywood sheets",
            createdByName: "Jordan"
        ))
        .environmentObject(POStore())
        .environmentObject(AuthStore())
    }
}
