import SwiftUI

/// Approval actions for a pending PO request. Managers approve directly; everyone else
/// can self-approve after a warning that it's only for authorized employees. Anyone can
/// decline, which requires a reason.
struct ApprovalControls: View {
    @EnvironmentObject private var store: POStore
    @EnvironmentObject private var authStore: AuthStore
    let po: PurchaseOrder
    @State private var showSelfApproveWarning = false
    @State private var showDeclineSheet = false

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

        Button(role: .destructive) {
            showDeclineSheet = true
        } label: {
            Label("Decline Request", systemImage: "xmark.seal")
        }
        .sheet(isPresented: $showDeclineSheet) {
            DeclineReasonSheet(po: po)
        }
    }
}

/// Collects the required reason before declining a request.
private struct DeclineReasonSheet: View {
    @EnvironmentObject private var store: POStore
    @EnvironmentObject private var authStore: AuthStore
    @Environment(\.dismiss) private var dismiss
    let po: PurchaseOrder
    @State private var reason = ""

    private var trimmedReason: String {
        reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    TextField("Why is this request being declined?", text: $reason, axis: .vertical)
                        .lineLimit(3...8)
                }
                .listRowBackground(Theme.panel)
            }
            .industrialForm()
            .navigationTitle("DECLINE REQUEST")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Decline") {
                        store.decline(po, by: authStore.currentUser, reason: trimmedReason)
                        dismiss()
                    }
                    .disabled(trimmedReason.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
