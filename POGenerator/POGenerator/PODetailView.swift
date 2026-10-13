import SwiftUI
import PhotosUI
import UIKit

struct PODetailView: View {
    @EnvironmentObject private var store: POStore
    @EnvironmentObject private var authStore: AuthStore
    let po: PurchaseOrder
    /// Set when arriving from History's status menu after picking a delivery status,
    /// so the receipt prompt and email flow run without a second tap.
    var deliveryIntentOnAppear: POStatus?

    @State private var hasAutoPrompted = false
    @State private var notesText: String = ""
    @State private var detailsText: String = ""
    /// Which attachment slot the camera / library is being opened for. One dialog and
    /// one pair of pickers serve all of them, so nothing competes to present. The
    /// target outlives the dialog -- it's still needed when the picker comes back.
    @State private var photoTarget: PhotoTarget?
    @State private var showPhotoOptions = false
    @State private var showCameraCapture = false
    @State private var showPhotoLibraryPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var exportPayload: ExportPayload?
    // Receipts awaiting a required dollar amount, prompted one at a time as uploaded.
    @State private var pendingAmountReceiptIDs: [String] = []
    // Set once at least one receipt amount was saved, so the "does this complete the
    // order?" question is asked once after the whole batch rather than per receipt.
    @State private var askCompletesOrder = false
    @State private var amountPromptText = ""
    @State private var viewingPhoto: PhotoSelection?
    @State private var showMailComposer = false
    @State private var showMailUnavailable = false
    @State private var showArchiveConfirmation = false
    /// Set when fulfillment happens while receipt-amount prompts are still queued, so
    /// the summary composer opens after the last one instead of fighting it.
    @State private var mailAfterPrompts = false

    /// Identifies which photo the full-screen viewer is showing, and how to remove it.
    private struct PhotoSelection: Identifiable {
        let id: String
        let fileName: String
        let title: String
        /// Nil when this photo can't be deleted from here.
        let delete: (() -> Void)?
    }

    /// Where a newly captured or picked photo should go.
    private enum PhotoTarget: Identifiable, Equatable {
        /// The PO's own request photos.
        case request
        /// A new receipt (each photo picked becomes its own receipt and amount).
        case newReceipt
        /// Another page of an existing receipt, covered by the amount already on it.
        case existingReceipt(id: String)

        var id: String {
            switch self {
            case .request: return "request"
            case .newReceipt: return "new-receipt"
            case .existingReceipt(let id): return "receipt-\(id)"
            }
        }

        var dialogTitle: String {
            switch self {
            case .request: return "Add Request Photo"
            case .newReceipt: return "Add Receipt Photo"
            case .existingReceipt: return "Add Photo to This Receipt"
            }
        }
    }
    // Single alert slot: SwiftUI only honors one .alert per view, so both prompts
    // share this one. Two stacked .alert modifiers silently dropped one of them.
    @State private var activePrompt: ActivePrompt?

    private enum ActivePrompt: Identifiable {
        /// A delivery status was picked but no receipt is attached yet.
        case needsReceipt(intended: POStatus)
        case receiptAmount(receiptID: String)
        /// Asked after receipts are logged: is the PO now complete, or are more
        /// deliveries still coming?
        case completesOrder

        var id: String {
            switch self {
            case .needsReceipt(let intended): return "needs-receipt-\(intended.rawValue)"
            case .receiptAmount(let receiptID): return "amount-\(receiptID)"
            case .completesOrder: return "completes-order"
            }
        }
    }

    private var current: PurchaseOrder {
        store.history.first(where: { $0.id == po.id }) ?? po
    }

    private var isDownloadingPhotos: Bool {
        store.downloadingPhotoPOIDs.contains(po.id)
    }

    /// Camera capture files the photo on set; a computed binding avoids an onChange on
    /// UIImage, which isn't Equatable.
    private var cameraBinding: Binding<UIImage?> {
        Binding(get: { nil }, set: { image in
            guard let image, let target = photoTarget else { return }
            attach(image, to: target)
            if case .newReceipt = target {
                scheduleNextAmountPrompt()
            }
            photoTarget = nil
        })
    }

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    private var statusBinding: Binding<POStatus> {
        Binding(
            get: { current.status },
            set: { newStatus in
                // Delivery statuses expect a receipt; nudge for one, but allow a bypass.
                if needsReceipt(for: newStatus) {
                    // Defer so the Picker's pushed selection screen finishes popping;
                    // presenting mid-transition swallows the alert.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        activePrompt = .needsReceipt(intended: newStatus)
                    }
                } else if newStatus.reportsDelivery {
                    applyDeliveryStatus(newStatus)
                } else {
                    store.setStatus(newStatus, for: current, by: authStore.currentUser)
                }
            }
        )
    }

    var body: some View {
        Form {
            if let syncError = store.errorMessage {
                Section {
                    Label("Not saved to iCloud", systemImage: "exclamationmark.icloud")
                        .foregroundColor(.red)
                    Text(syncError)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button("Dismiss") { store.errorMessage = nil }
                }
                .listRowBackground(Theme.panel)
            }

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

            Section("Description") {
                TextField("List Materials Needed Here", text: $detailsText, axis: .vertical)
                    .lineLimit(3...10)
                Text("Editable at any point — changes sync to the whole team.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .listRowBackground(Theme.panel)

            Section("Photos") {
                if !current.photoFileNames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(current.photoFileNames, id: \.self) { fileName in
                                photoThumbnail(
                                    fileName: fileName,
                                    size: 120,
                                    title: "Request Photo",
                                    delete: { store.removePhoto(fileName: fileName, from: current) }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Button {
                    requestPhoto(.request)
                } label: {
                    Label(
                        current.photoFileNames.isEmpty ? "Add Photos" : "Add More Photos",
                        systemImage: "camera"
                    )
                }

                if isDownloadingPhotos {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Downloading photos from iCloud…")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(current.photoFileNames.isEmpty
                         ? "Photos can be added at any point in the PO's life."
                         : "Tap a photo to zoom in, share, or delete it.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .listRowBackground(Theme.panel)

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
            }

            Section("Fulfillment Notes") {
                TextField("Add notes about fulfillment...", text: $notesText, axis: .vertical)
                    .lineLimit(3...8)
            }
            .listRowBackground(Theme.panel)

            if current.isApproved {
                receiptsSection

                if current.status.reportsDelivery {
                    Section("Summary Email") {
                        Button {
                            if POMail.canSend {
                                showMailComposer = true
                            } else {
                                showMailUnavailable = true
                            }
                        } label: {
                            Label("Email PO Summary", systemImage: "envelope")
                        }
                        Text("Sends the full PO — details, notes, receipt amounts, and all photos — to \(POMail.recipient).")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        if isDownloadingPhotos {
                            Text("Photos are still downloading — wait for them to finish or the email will go without them.")
                                .font(.footnote)
                                .foregroundColor(.orange)
                        }
                    }
                    .listRowBackground(Theme.panel)
                }
            }

            if authStore.currentUser?.isManager == true {
                Section("Manager") {
                    Button(role: current.isArchived ? .none : .destructive) {
                        showArchiveConfirmation = true
                    } label: {
                        Label(
                            current.isArchived ? "Restore PO" : "Archive PO",
                            systemImage: current.isArchived ? "tray.and.arrow.up" : "archivebox"
                        )
                    }
                    if current.isArchived, let by = current.archivedByName, let at = current.archivedAt {
                        Text("Archived by \(by) on \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .listRowBackground(Theme.panel)
            }
        }
        .industrialForm()
        .navigationTitle("PO DETAILS")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            notesText = current.fulfillmentNotes
            detailsText = current.details
            autoPromptFulfillIfNeeded()
        }
        .task {
            // History fetches metadata only so the list stays fast; the photos for this
            // one PO come down now.
            await store.ensurePhotos(for: current)
        }
        .onDisappear {
            // Don't leave a just-typed edit sitting in the debounce window.
            store.flushPendingPushes()
        }
        .onChange(of: notesText) { newValue in
            store.setFulfillmentNotes(newValue, for: current)
        }
        .onChange(of: detailsText) { newValue in
            store.setDetails(newValue, for: current)
        }
        .confirmationDialog(
            photoTarget?.dialogTitle ?? "Add Photo",
            isPresented: $showPhotoOptions,
            titleVisibility: .visible
        ) {
            if cameraAvailable {
                Button("Take Photo") { showCameraCapture = true }
            }
            Button("Choose from Library") { showPhotoLibraryPicker = true }
            Button("Cancel", role: .cancel) { photoTarget = nil }
        }
        .photosPicker(isPresented: $showPhotoLibraryPicker, selection: $photoPickerItems, matching: .images)
        .onChange(of: photoPickerItems) { newItems in
            guard !newItems.isEmpty, let target = photoTarget else { return }
            Task {
                var addedReceipt = false
                for item in newItems {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data)
                    else { continue }
                    if attach(image, to: target) && target == .newReceipt {
                        addedReceipt = true
                    }
                }
                photoPickerItems = []
                photoTarget = nil
                if addedReceipt {
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
        .fullScreenCover(item: $viewingPhoto) { selection in
            PhotoViewerView(
                fileName: selection.fileName,
                title: selection.title,
                onDelete: selection.delete
            )
        }
        .sheet(isPresented: $showMailComposer) {
            POMailComposeView(po: current)
        }
        .alert("Mail Not Set Up", isPresented: $showMailUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device has no email account configured in the Mail app, so the summary can't be composed. Add an account in Settings → Mail, then try again.")
        }
        .confirmationDialog(
            current.isArchived ? "Restore this PO?" : "Archive this PO?",
            isPresented: $showArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button(current.isArchived ? "Restore" : "Archive", role: current.isArchived ? .none : .destructive) {
                store.setArchived(!current.isArchived, for: current, by: authStore.currentUser)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(current.isArchived
                 ? "It will move back into the main History list."
                 : "It stays recorded and keeps its PO number, but is hidden from the main History list. You can restore it later.")
        }
        .alert(promptTitle, isPresented: promptPresented, presenting: activePrompt) { prompt in
            switch prompt {
            case .needsReceipt(let intended):
                Button("Add Receipt Photo") {
                    // Defer so the alert finishes dismissing before the dialog presents.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        requestPhoto(.newReceipt)
                    }
                }
                Button("Mark \(intended.label) Anyway") {
                    applyDeliveryStatus(intended)
                }
                Button("Cancel", role: .cancel) {}

            case .receiptAmount(let receiptID):
                TextField("0.00", text: $amountPromptText)
                    .keyboardType(.decimalPad)
                Button("Save") {
                    if let amount = parseAmount(amountPromptText), amount > 0 {
                        store.setReceiptAmount(amount, receiptID: receiptID, for: current)
                        // A logged delivery -- ask whether it finishes the order.
                        askCompletesOrder = true
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

            case .completesOrder:
                Button("Yes — Order Complete") {
                    applyDeliveryStatus(.fulfilled)
                }
                Button("No — More Coming") {
                    applyDeliveryStatus(.partiallyFulfilled)
                }
            }
        } message: { prompt in
            switch prompt {
            case .needsReceipt(let intended):
                Text("Marking this PO \(intended.label.lowercased()) usually includes a receipt photo. Add one now, or set the status anyway.")
            case .receiptAmount:
                Text("A dollar amount is required for each receipt. Cancelling discards this receipt photo.")
            case .completesOrder:
                Text("Does this delivery complete the order? Either way the summary email opens next.")
            }
        }
    }

    private var promptTitle: String {
        switch activePrompt {
        case .receiptAmount: return "Enter Receipt Amount"
        case .completesOrder: return "Order Complete?"
        default: return "Add a Receipt?"
        }
    }

    private var promptPresented: Binding<Bool> {
        Binding(get: { activePrompt != nil }, set: { if !$0 { activePrompt = nil } })
    }

    /// Opens the camera-or-library dialog for one attachment slot.
    private func requestPhoto(_ target: PhotoTarget) {
        photoTarget = target
        showPhotoOptions = true
    }

    /// Files a captured or picked photo against its target. Returns false if the save
    /// failed. New-receipt photos are queued for their required amount prompt.
    @discardableResult
    private func attach(_ image: UIImage, to target: PhotoTarget) -> Bool {
        switch target {
        case .request:
            return store.addPhoto(image, to: current) != nil
        case .newReceipt:
            guard let receiptID = store.addReceipt(image, for: current) else { return false }
            pendingAmountReceiptIDs.append(receiptID)
            return true
        case .existingReceipt(let receiptID):
            // Another page of a receipt already carrying an amount -- no prompt.
            return store.addReceiptPhoto(image, toReceipt: receiptID, for: current) != nil
        }
    }

    /// Tappable thumbnail that opens the zoomable viewer, with an optional delete.
    @ViewBuilder
    private func photoThumbnail(
        fileName: String,
        size: CGFloat,
        title: String,
        delete: (() -> Void)?
    ) -> some View {
        if let image = PhotoStore.loadImage(fileName: fileName) {
            Button {
                viewingPhoto = PhotoSelection(
                    id: fileName,
                    fileName: fileName,
                    title: title,
                    delete: delete
                )
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        } else {
            // Asset hasn't downloaded to this device yet.
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.steel.opacity(0.25))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundColor(Theme.steel)
                }
        }
    }

    /// Arriving from History's status menu: honor the delivery status that was picked
    /// by prompting for a receipt (or applying it directly if one already exists).
    /// Runs once.
    private func autoPromptFulfillIfNeeded() {
        guard let intent = deliveryIntentOnAppear, !hasAutoPrompted, current.isApproved else { return }
        hasAutoPrompted = true

        guard needsReceipt(for: intent) else {
            applyDeliveryStatus(intent)
            return
        }
        // Let the push transition finish before presenting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            activePrompt = .needsReceipt(intended: intent)
        }
    }

    /// Whether moving to `newStatus` should ask for a receipt first. Nothing documented
    /// yet clearly needs one; so does completing a partially-fulfilled PO, since that
    /// means a further delivery arrived and the existing receipts cover earlier ones.
    private func needsReceipt(for newStatus: POStatus) -> Bool {
        guard newStatus.reportsDelivery else { return false }
        if current.receipts.isEmpty { return true }
        return current.status == .partiallyFulfilled && newStatus == .fulfilled
    }

    /// Records a delivery status (fulfilled or partially fulfilled) and offers the
    /// summary email. iOS can't send mail on its own, so this opens the pre-filled
    /// composer -- the user taps Send.
    private func applyDeliveryStatus(_ status: POStatus) {
        store.setStatus(status, for: current, by: authStore.currentUser)
        guard POMail.canSend else { return }

        // A sheet can't present over an alert. If any prompt is showing or queued, hand
        // off to scheduleNextAmountPrompt, which opens the composer once they drain.
        if activePrompt != nil || !pendingAmountReceiptIDs.isEmpty || askCompletesOrder {
            mailAfterPrompts = true
            scheduleNextAmountPrompt()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            showMailComposer = true
        }
    }

    /// Shows the amount prompt for the next just-uploaded receipt, after a short delay
    /// so any dismissing camera/library/alert presentation clears first.
    private func scheduleNextAmountPrompt() {
        // Nothing queued -- don't spin.
        guard !pendingAmountReceiptIDs.isEmpty || askCompletesOrder || mailAfterPrompts else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard activePrompt == nil else {
                // Something is still on screen; check again once it clears.
                scheduleNextAmountPrompt()
                return
            }

            if !pendingAmountReceiptIDs.isEmpty {
                let next = pendingAmountReceiptIDs.removeFirst()
                amountPromptText = ""
                activePrompt = .receiptAmount(receiptID: next)
            } else if askCompletesOrder {
                // All amounts logged -- now ask whether the order is finished. The
                // answer sets the status and queues the email.
                askCompletesOrder = false
                activePrompt = .completesOrder
            } else if mailAfterPrompts {
                // Amount prompts are done, so the composer can safely present now.
                mailAfterPrompts = false
                showMailComposer = true
            }
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
            ForEach(Array(current.receipts.enumerated()), id: \.element.id) { index, receipt in
                ReceiptRow(
                    po: current,
                    receipt: receipt,
                    number: index + 1,
                    total: current.receipts.count,
                    thumbnail: { fileName in
                        photoThumbnail(
                            fileName: fileName,
                            size: 150,
                            title: "Receipt",
                            delete: { store.removeReceiptPhoto(fileName: fileName, fromReceipt: receipt.id, for: current) }
                        )
                    },
                    onAddPhoto: { requestPhoto(.existingReceipt(id: receipt.id)) }
                )
            }

            Button {
                requestPhoto(.newReceipt)
            } label: {
                Label("Add Receipt", systemImage: "doc.viewfinder")
            }

            Text("Each photo added here becomes its own receipt with its own amount. For a long receipt or a multi-page invoice, use Add Photo on the receipt itself.")
                .font(.footnote)
                .foregroundColor(.secondary)

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

/// One receipt: its photos (several, for a long receipt or a multi-page invoice), the
/// one dollar amount they add up to, and a remove button. Owns its amount text state so
/// typing (e.g. a trailing ".") isn't reformatted mid-entry.
private struct ReceiptRow<Thumbnail: View>: View {
    @EnvironmentObject private var store: POStore
    let po: PurchaseOrder
    let receipt: Receipt
    let number: Int
    let total: Int
    /// Supplied by the parent so the photo viewer and its delete flow stay in one place.
    let thumbnail: (String) -> Thumbnail
    let onAddPhoto: () -> Void

    @State private var amountText: String = ""
    @State private var showDeleteConfirmation = false
    @FocusState private var amountFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(total > 1 ? "Receipt \(number) of \(total)" : "Receipt")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if receipt.photoFileNames.count > 1 {
                    Text("\(receipt.photoFileNames.count) photos")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(receipt.photoFileNames, id: \.self) { fileName in
                        thumbnail(fileName)
                    }

                    Button(action: onAddPhoto) {
                        VStack(spacing: 6) {
                            Image(systemName: "plus.viewfinder")
                                .font(.title2)
                            Text("Add Photo")
                                .font(.caption2)
                        }
                        .frame(width: 150, height: 150)
                        .background(Theme.steel.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.accent)
                }
                .padding(.vertical, 2)
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
            receipt.photoFileNames.count > 1 ? "Delete this receipt and its \(receipt.photoFileNames.count) photos?" : "Delete this receipt?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Receipt", role: .destructive) {
                store.removeReceipt(receipt, for: po)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The amount goes with it. To remove just one photo, tap that photo and delete it there.")
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
