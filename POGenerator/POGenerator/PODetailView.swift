import SwiftUI

struct PODetailView: View {
    @EnvironmentObject private var store: POStore
    @EnvironmentObject private var authStore: AuthStore
    let po: PurchaseOrder

    private var current: PurchaseOrder {
        store.history.first(where: { $0.id == po.id }) ?? po
    }

    var body: some View {
        Form {
            Section("PO Number") {
                Text(current.poNumber)
                    .font(.system(.title2, design: .monospaced))
                    .bold()
            }

            Section("Job") {
                LabeledContent("Job Number", value: current.jobNumber)
                LabeledContent("Customer", value: current.customerName)
                LabeledContent("Created By", value: current.createdByName)
                LabeledContent("Created", value: current.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            if !current.details.isEmpty {
                Section("Description") {
                    Text(current.details)
                }
            }

            if let fileName = current.photoFileName, let image = PhotoStore.loadImage(fileName: fileName) {
                Section("Photo") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            Section("Fulfillment") {
                Toggle("Fulfilled", isOn: Binding(
                    get: { current.isFulfilled },
                    set: { newValue in
                        store.setFulfilled(newValue, for: current, by: authStore.currentUser)
                    }
                ))

                if current.isFulfilled, let fulfilledBy = current.fulfilledByName {
                    LabeledContent("Fulfilled By", value: fulfilledBy)
                    if let fulfilledAt = current.fulfilledAt {
                        LabeledContent("Fulfilled At", value: fulfilledAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
        }
        .navigationTitle("PO Details")
        .navigationBarTitleDisplayMode(.inline)
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
            createdByName: "Jordan",
            createdByPhone: "555-0100",
            isFulfilled: false,
            fulfilledByName: nil,
            fulfilledAt: nil
        ))
        .environmentObject(POStore())
        .environmentObject(AuthStore())
    }
}
