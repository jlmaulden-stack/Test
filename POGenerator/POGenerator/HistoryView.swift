import SwiftUI

/// Navigation target for a PO, optionally carrying the intent to immediately prompt
/// for a receipt (when Fulfilled was picked from the History menu on a PO with none).
struct PORoute: Hashable {
    let po: PurchaseOrder
    /// Set when a delivery status was picked from the History menu, so the detail page
    /// can run the receipt prompt and email flow for that specific status.
    var deliveryIntent: POStatus?
}

struct HistoryView: View {
    @EnvironmentObject private var store: POStore
    @EnvironmentObject private var authStore: AuthStore
    @State private var searchText = ""
    @State private var sort: HistorySort = .dateNewest
    @State private var statusFilter: POStatus?
    @State private var showArchived = false
    @State private var exportPayload: ExportPayload?
    @State private var path: [PORoute] = []

    private var hasReceipts: Bool {
        store.history.contains { !$0.receipts.isEmpty }
    }

    private var isManager: Bool {
        authStore.currentUser?.isManager == true
    }

    /// History filtered by archive state, the status filter, and the search term
    /// (customer name or job number), then sorted.
    private var displayedHistory: [PurchaseOrder] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = store.history.filter { po in
            let matchesArchive = po.isArchived == showArchived
            let matchesStatus = statusFilter == nil || po.status == statusFilter
            let matchesQuery = query.isEmpty
                || po.customerName.lowercased().contains(query)
                || po.jobNumber.lowercased().contains(query)
            return matchesArchive && matchesStatus && matchesQuery
        }
        return sort.sorted(filtered)
    }

    /// Anything still in play -- pending, declined, new, acknowledged.
    private var activeHistory: [PurchaseOrder] {
        displayedHistory.filter { $0.status != .fulfilled || !$0.isApproved }
    }

    /// Completed work, listed separately below the active list.
    private var fulfilledHistory: [PurchaseOrder] {
        displayedHistory.filter { $0.status == .fulfilled && $0.isApproved }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.history.isEmpty && !store.isLoadingHistory {
                    emptyState
                } else if displayedHistory.isEmpty {
                    noMatchesState
                } else {
                    List {
                        if !activeHistory.isEmpty {
                            Section(showArchived ? "Archived — Open" : "Open") {
                                ForEach(activeHistory) { po in
                                    row(for: po)
                                }
                            }
                        }

                        if !fulfilledHistory.isEmpty {
                            Section("Fulfilled") {
                                ForEach(fulfilledHistory) { po in
                                    row(for: po)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Theme.background)
                    .navigationDestination(for: PORoute.self) { route in
                        PODetailView(po: route.po, deliveryIntentOnAppear: route.deliveryIntent)
                    }
                    .refreshable {
                        await store.loadHistory()
                    }
                }
            }
            .navigationTitle("HISTORY")
            .safeAreaInset(edge: .top) {
                if let syncError = store.errorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("iCloud sync problem", systemImage: "exclamationmark.icloud")
                            .font(.footnote)
                            .bold()
                            .foregroundColor(.red)
                        Text(syncError)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.panel)
                    .onTapGesture { store.errorMessage = nil }
                }
            }
            .searchable(text: $searchText, prompt: "Customer or job number")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        exportPayload = ExportPayload(urls: ReceiptExporter.exportURLs(forAll: store.history))
                    } label: {
                        Label("Export Receipts", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!hasReceipts)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    filterMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                }
            }
            .sheet(item: $exportPayload) { payload in
                ShareSheet(items: payload.urls)
            }
            .task {
                await store.loadHistory()
            }
        }
    }

    private func row(for po: PurchaseOrder) -> some View {
        NavigationLink(value: PORoute(po: po)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if po.isApproved {
                        Text(po.poNumber)
                            .font(.system(.body, design: .monospaced))
                            .bold()
                            .foregroundColor(Theme.accent)
                        Spacer()
                        statusMenu(for: po)
                    } else if po.isDeclined {
                        Label("DECLINED", systemImage: "xmark.seal")
                            .font(.system(.caption, design: .monospaced))
                            .bold()
                            .foregroundColor(.red)
                        Spacer()
                    } else {
                        Label("PENDING APPROVAL", systemImage: "clock.badge.questionmark")
                            .font(.system(.caption, design: .monospaced))
                            .bold()
                            .foregroundColor(.orange)
                        Spacer()
                    }
                }
                if po.isApproved, let updatedBy = po.statusUpdatedByName {
                    Text("\(po.status.label) by \(updatedBy)")
                        .font(.caption2)
                        .foregroundColor(po.status.color)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Text("\(po.customerName) · Job \(po.jobNumber)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("By \(po.createdByName) · \(po.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(Theme.panel)
        .swipeActions(edge: .trailing) {
            if isManager {
                Button(role: po.isArchived ? .none : .destructive) {
                    store.setArchived(!po.isArchived, for: po, by: authStore.currentUser)
                } label: {
                    Label(
                        po.isArchived ? "Restore" : "Archive",
                        systemImage: po.isArchived ? "tray.and.arrow.up" : "archivebox"
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundColor(Theme.steel)
            Text("No POs Yet")
                .font(.headline)
            Text("Purchase orders generated by you or your team will show up here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(Theme.steel)
            Text("No Matches")
                .font(.headline)
            Text(noMatchesDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var noMatchesDescription: String {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmed.isEmpty, statusFilter) {
        case (false, .some(let status)):
            return "No \(status.label) purchase orders match \"\(trimmed)\"."
        case (false, .none):
            return "No purchase orders match \"\(trimmed)\"."
        case (true, .some(let status)):
            return "No purchase orders are marked \(status.label)."
        case (true, .none):
            return "No purchase orders to show."
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter by Status", selection: $statusFilter) {
                Label("All Statuses", systemImage: "line.3.horizontal.decrease")
                    .tag(POStatus?.none)
                ForEach(POStatus.allCases) { status in
                    Label(status.label, systemImage: status.systemImage)
                        .tag(POStatus?.some(status))
                }
            }

            Divider()

            Toggle(isOn: $showArchived) {
                Label("Show Archived", systemImage: "archivebox")
            }
        } label: {
            Label("Filter", systemImage: (statusFilter == nil && !showArchived)
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(HistorySort.allCases) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    private func statusMenu(for po: PurchaseOrder) -> some View {
        Menu {
            ForEach(POStatus.allCases) { status in
                Button {
                    if status.reportsDelivery {
                        // Delivery statuses open the receipt prompt and the summary
                        // email, both of which live on the detail page -- go there
                        // instead of flipping the status in place.
                        path.append(PORoute(po: po, deliveryIntent: status))
                    } else {
                        store.setStatus(status, for: po, by: authStore.currentUser)
                    }
                } label: {
                    Label(status.label, systemImage: status.systemImage)
                }
            }
        } label: {
            Label(po.status.label, systemImage: po.status.systemImage)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundColor(po.status.color)
                // Fixed-width, leading-aligned block keeps the icon in the same
                // vertical column across rows so it doesn't shift as the label changes.
                .frame(width: 112, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
    }
}

#Preview {
    HistoryView()
        .environmentObject(POStore())
        .environmentObject(AuthStore())
}
