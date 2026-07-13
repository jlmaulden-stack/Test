import SwiftUI
import PhotosUI
import UIKit

struct GenerateView: View {
    @EnvironmentObject private var store: POStore
    @EnvironmentObject private var authStore: AuthStore
    @FocusState private var focusedField: Field?
    @State private var showCopiedToast = false
    @State private var details = ""
    @State private var selectedImages: [UIImage] = []
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var showCameraCapture = false
    @State private var showPhotoLibraryPicker = false
    @State private var showAttachmentOptions = false

    /// Camera capture appends to the photo list on set; a computed binding avoids an
    /// onChange on UIImage, which isn't Equatable.
    private var cameraBinding: Binding<UIImage?> {
        Binding(get: { nil }, set: { image in
            if let image { selectedImages.append(image) }
        })
    }

    enum Field {
        case jobNumber, customerName, details
    }

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Job") {
                    TextField("Job Number", text: $store.jobNumber)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focusedField, equals: .jobNumber)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .customerName }

                    TextField("Customer Name", text: $store.customerName)
                        .focused($focusedField, equals: .customerName)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .details }
                }
                .listRowBackground(Theme.panel)

                Section("Description") {
                    TextField("List Materials Needed Here", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($focusedField, equals: .details)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                }
                .listRowBackground(Theme.panel)

                Section("Photos") {
                    if !selectedImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 90, height: 90)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                        Button {
                                            selectedImages.remove(at: index)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.white)
                                                .background(Circle().fill(.black.opacity(0.5)))
                                        }
                                        .buttonStyle(.borderless)
                                        .padding(4)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Button(selectedImages.isEmpty ? "Add Photos" : "Add More Photos") {
                        showAttachmentOptions = true
                    }
                }
                .listRowBackground(Theme.panel)

                Section {
                    Button {
                        submitGenerate()
                    } label: {
                        HStack {
                            Spacer()
                            if store.isGenerating {
                                ProgressView()
                            } else {
                                Text("REQUEST PO")
                                    .font(.system(.headline, design: .monospaced))
                                    .bold()
                                    .foregroundColor(.black)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!store.canRequest || store.isGenerating)
                }
                .listRowBackground(
                    (store.canRequest && !store.isGenerating) ? Theme.accent : Theme.accent.opacity(0.35)
                )

                if let po = store.lastGenerated {
                    Section(po.isApproved ? "Generated PO" : "Requested PO") {
                        VStack(alignment: .leading, spacing: 8) {
                            if po.isApproved {
                                Text(po.poNumber)
                                    .font(.system(.largeTitle, design: .monospaced))
                                    .bold()
                                    .foregroundColor(Theme.accent)
                            } else if po.isDeclined {
                                Text("DECLINED")
                                    .font(.system(.headline, design: .monospaced))
                                    .bold()
                                    .foregroundColor(.red)
                            } else {
                                Text("PENDING APPROVAL")
                                    .font(.system(.headline, design: .monospaced))
                                    .bold()
                                    .foregroundColor(.orange)
                            }
                            Text("\(po.customerName) · Job \(po.jobNumber)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)

                        if po.isApproved {
                            Button {
                                UIPasteboard.general.string = po.poNumber
                                showCopiedToast = true
                            } label: {
                                Label("Copy PO Number", systemImage: "doc.on.doc")
                            }
                        } else if po.isDeclined {
                            if let reason = po.declineReason, !reason.isEmpty {
                                Text("Reason: \(reason)")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("A PO number is assigned once this request is approved.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            ApprovalControls(po: po)
                        }
                    }
                    .listRowBackground(Theme.panel)
                }

                if let errorMessage = store.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                    .listRowBackground(Theme.panel)
                }
            }
            .industrialForm()
            .navigationTitle("NEW PO")
            .confirmationDialog("Add Photo", isPresented: $showAttachmentOptions) {
                if cameraAvailable {
                    Button("Take Photo") { showCameraCapture = true }
                }
                Button("Choose from Library") { showPhotoLibraryPicker = true }
            }
            .photosPicker(isPresented: $showPhotoLibraryPicker, selection: $photosPickerItems, matching: .images)
            .onChange(of: photosPickerItems) { newItems in
                guard !newItems.isEmpty else { return }
                Task {
                    for item in newItems {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            selectedImages.append(image)
                        }
                    }
                    photosPickerItems = []
                }
            }
            .fullScreenCover(isPresented: $showCameraCapture) {
                CameraCaptureView(image: cameraBinding)
                    .ignoresSafeArea()
            }
            .overlay(alignment: .bottom) {
                if showCopiedToast {
                    Text("Copied")
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(for: .seconds(1.5))
                            showCopiedToast = false
                        }
                }
            }
        }
    }

    private func submitGenerate() {
        focusedField = nil
        guard let user = authStore.currentUser else { return }
        let submittedDetails = details
        let submittedImages = selectedImages
        Task {
            await store.requestPO(details: submittedDetails, photos: submittedImages, createdBy: user)
            details = ""
            selectedImages = []
        }
    }
}

#Preview {
    GenerateView()
        .environmentObject(POStore())
        .environmentObject(AuthStore())
}
