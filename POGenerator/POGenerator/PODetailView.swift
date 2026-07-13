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
    @State private var showFulfillWithoutReceiptPrompt = false
    @State private var exportPayload: ExportPayload?
    // Set when the user chose "Add Receipt Photo" from the fulfilled prompt, so the
    // status flips to Fulfilled once a receipt is actually added.
    @State private var fulfillAfterReceipt = false

    private var current: PurchaseOrder {
        store.history.first(where: { $0.id == po.id }) ?? po
    }

    /// Camera capture adds a receipt on set; a computed binding avoids an onChange on
    /// UIImage, which isn't Equatable.
    private var cameraBinding: Binding<UIImage?> {
        Binding(get: { nil }, set: { image in
            if let image {
                store.addReceipt(image, for: current)
                applyPendingFulfillmentIfNeeded()
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
                    showFulfillWithoutReceiptPrompt = true
                } else {
                    store.setStatus(newStatus, for: current, by: authStore.currentUser)
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("PO Number") {
                Text(current.poNumber)
                    .font(.system(.title2, design: .monospaced))
                    .bold()
                    .foregroundColor(Theme.accent)
            }
            .listRowBackground(Theme.panel)

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

            Section("Status") {
                Picker("Status", selection: statusBinding) {
                    ForEach(POStatus.allCases) { status in
                        Label(status.label, systemImage: status.systemImage).tag(status)
                    }
                }

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
                       let image = UIImage(data: data) {
                        store.addReceipt(image, for: current)
                        addedAny = true
                    }
                }
                receiptPickerItems = []
                if addedAny { applyPendingFulfillmentIfNeeded() }
            }
        }
        .fullScreenCover(isPresented: $showCameraCapture) {
            CameraCaptureView(image: cameraBinding)
                .ignoresSafeArea()
        }
        .sheet(item: $exportPayload) { payload in
            ShareSheet(items: payload.urls)
        }
        .alert("Add a Receipt?", isPresented: $showFulfillWithoutReceiptPrompt) {
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
        } message: {
            Text("Marking this PO fulfilled usually includes a receipt photo. Add one now, or mark it fulfilled anyway.")
        }
    }

    /// After a receipt is added as part of the "mark fulfilled" flow, complete the
    /// status change.
    private func applyPendingFulfillmentIfNeeded() {
        guard fulfillAfterReceipt else { return }
        fulfillAfterReceipt = false
        store.setStatus(.fulfilled, for: current, by: authStore.currentUser)
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
