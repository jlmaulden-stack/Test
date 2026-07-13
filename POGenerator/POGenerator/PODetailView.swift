import SwiftUI

struct PODetailView: View {
    @EnvironmentObject private var store: POStore
    @EnvironmentObject private var authStore: AuthStore
    let po: PurchaseOrder
    @State private var notesText: String = ""

    private var current: PurchaseOrder {
        store.history.first(where: { $0.id == po.id }) ?? po
    }

    private var statusBinding: Binding<POStatus> {
        Binding(
            get: { current.status },
            set: { newStatus in
                store.setStatus(newStatus, for: current, by: authStore.currentUser)
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
                Picker(selection: statusBinding) {
                    ForEach(POStatus.allCases) { status in
                        Label(status.label, systemImage: status.systemImage).tag(status)
                    }
                } label: {
                    Label(current.status.label, systemImage: current.status.systemImage)
                        .foregroundColor(current.status.color)
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
