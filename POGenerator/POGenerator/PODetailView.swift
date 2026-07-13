import SwiftUI
import PhotosUI
import UIKit

struct PODetailView: View {
    @EnvironmentObject private var store: POStore
    @EnvironmentObject private var authStore: AuthStore
    let po: PurchaseOrder

    @State private var notesText: String = ""
    @State private var amountText: String = ""
    @State private var showReceiptOptions = false
    @State private var showCameraCapture = false
    @State private var showPhotoLibraryPicker = false
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var showFulfillWithoutReceiptPrompt = false
    @State private var exportPayload: ExportPayload?

    private var current: PurchaseOrder {
        store.history.first(where: { $0.id == po.id }) ?? po
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
                if newStatus == .fulfilled && current.receiptPhotoFileName == nil {
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

            if let fileName = current.photoFileName, let image = PhotoStore.loadImage(fileName: fileName) {
                Section("Photo") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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

            Section("Amount") {
                HStack {
                    Text("$")
                        .foregroundColor(.secondary)
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                }
            }
            .listRowBackground(Theme.panel)

            receiptSection
        }
        .industrialForm()
        .navigationTitle("PO DETAILS")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            notesText = current.fulfillmentNotes
            amountText = current.amount.map { String(format: "%.2f", $0) } ?? ""
        }
        .onChange(of: notesText) { newValue in
            store.setFulfillmentNotes(newValue, for: current)
        }
        .onChange(of: amountText) { newValue in
            store.setAmount(parseAmount(newValue), for: current)
        }
        .confirmationDialog("Receipt Photo", isPresented: $showReceiptOptions) {
            if cameraAvailable {
                Button("Take Photo") { showCameraCapture = true }
            }
            Button("Choose from Library") { showPhotoLibraryPicker = true }
            if current.receiptPhotoFileName != nil {
                Button("Remove Receipt", role: .destructive) {
                    store.setReceiptPhoto(nil, for: current)
                }
            }
        }
        .photosPicker(isPresented: $showPhotoLibraryPicker, selection: $photosPickerItem, matching: .images)
        .onChange(of: photosPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    store.setReceiptPhoto(image, for: current)
                }
                photosPickerItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCameraCapture) {
            CameraCaptureView(image: Binding(
                get: { nil },
                set: { image in
                    if let image { store.setReceiptPhoto(image, for: current) }
                }
            ))
            .ignoresSafeArea()
        }
        .sheet(item: $exportPayload) { payload in
            ShareSheet(items: payload.urls)
        }
        .alert("Add a Receipt?", isPresented: $showFulfillWithoutReceiptPrompt) {
            Button("Add Receipt Photo") {
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

    @ViewBuilder
    private var receiptSection: some View {
        Section("Receipt") {
            if let fileName = current.receiptPhotoFileName, let image = PhotoStore.loadImage(fileName: fileName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Button {
                    if let url = ReceiptExporter.exportURL(for: current) {
                        exportPayload = ExportPayload(urls: [url])
                    }
                } label: {
                    Label("Export Receipt", systemImage: "square.and.arrow.up")
                }

                Button("Change Receipt") { showReceiptOptions = true }
            } else {
                Button {
                    showReceiptOptions = true
                } label: {
                    Label("Upload Receipt Photo", systemImage: "doc.viewfinder")
                }
            }
        }
        .listRowBackground(Theme.panel)
    }

    /// Parses a currency-ish string ("$1,500.50", "1500") into a Double, or nil if empty.
    private func parseAmount(_ text: String) -> Double? {
        let cleaned = text.filter { $0.isNumber || $0 == "." }
        return cleaned.isEmpty ? nil : Double(cleaned)
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
            photoFileName: nil,
            createdByName: "Jordan"
        ))
        .environmentObject(POStore())
        .environmentObject(AuthStore())
    }
}
