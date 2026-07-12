import SwiftUI
import PhotosUI
import UIKit

struct GenerateView: View {
    @EnvironmentObject private var store: POStore
    @EnvironmentObject private var authStore: AuthStore
    @FocusState private var focusedField: Field?
    @State private var showCopiedToast = false
    @State private var details = ""
    @State private var selectedImage: UIImage?
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var showCameraCapture = false
    @State private var showPhotoLibraryPicker = false
    @State private var showAttachmentOptions = false

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
                    TextField("What's this PO for? (optional)", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($focusedField, equals: .details)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                }
                .listRowBackground(Theme.panel)

                Section("Photo") {
                    if let selectedImage {
                        Image(uiImage: selectedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Button(selectedImage == nil ? "Add Photo" : "Change Photo") {
                        showAttachmentOptions = true
                    }

                    if selectedImage != nil {
                        Button("Remove Photo", role: .destructive) {
                            selectedImage = nil
                        }
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
                                Text("GENERATE PO NUMBER")
                                    .font(.system(.headline, design: .monospaced))
                                    .bold()
                                    .foregroundColor(.black)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!store.canGenerate || store.isGenerating)
                }
                .listRowBackground(
                    (store.canGenerate && !store.isGenerating) ? Theme.accent : Theme.accent.opacity(0.35)
                )

                if let po = store.lastGenerated {
                    Section("Generated PO") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(po.poNumber)
                                .font(.system(.largeTitle, design: .monospaced))
                                .bold()
                                .foregroundColor(Theme.accent)
                            Text("\(po.customerName) · Job \(po.jobNumber)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)

                        Button {
                            UIPasteboard.general.string = po.poNumber
                            showCopiedToast = true
                        } label: {
                            Label("Copy PO Number", systemImage: "doc.on.doc")
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
            .photosPicker(isPresented: $showPhotoLibraryPicker, selection: $photosPickerItem, matching: .images)
            .onChange(of: photosPickerItem) { newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        selectedImage = image
                    }
                    photosPickerItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCameraCapture) {
                CameraCaptureView(image: $selectedImage)
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
        let submittedImage = selectedImage
        Task {
            await store.generate(details: submittedDetails, photo: submittedImage, createdBy: user)
            details = ""
            selectedImage = nil
        }
    }
}

#Preview {
    GenerateView()
        .environmentObject(POStore())
        .environmentObject(AuthStore())
}
