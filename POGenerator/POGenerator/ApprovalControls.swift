import SwiftUI

/// Approval action for a pending PO request. Managers approve directly; everyone else
/// can self-approve after a warning that it's only for authorized employees.
struct ApprovalControls: View {
    @EnvironmentObject private var store: POStore
    @EnvironmentObject private var authStore: AuthStore
    let po: PurchaseOrder
    @State private var showSelfApproveWarning = false

    private var isManager: Bool {
        authStore.currentUser?.isManager == true
    }

    var body: some View {
        if isManager {
            Button {
                store.approve(po, by: authStore.currentUser, selfApproved: false)
            } label: {
                Label("Approve PO", systemImage: "checkmark.seal")
            }
        } else {
            Button {
                showSelfApproveWarning = true
            } label: {
                Label("Self-Approve", systemImage: "checkmark.seal")
            }
            .alert("Self-Approve PO?", isPresented: $showSelfApproveWarning) {
                Button("Self-Approve", role: .destructive) {
                    store.approve(po, by: authStore.currentUser, selfApproved: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("PO requests are normally approved by a manager. Self-approval is only for authorized employees. Continue?")
            }
        }
    }
}
