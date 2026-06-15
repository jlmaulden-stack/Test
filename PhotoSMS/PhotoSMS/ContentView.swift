import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                photoPreview

                if !viewModel.statusMessage.isEmpty {
                    Text(viewModel.statusMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                actionButtons
            }
            .padding(.vertical)
            .navigationTitle("Photo SMS")
            .sheet(isPresented: $viewModel.showCamera) {
                CameraPicker(
                    image: $viewModel.capturedImage,
                    isPresented: $viewModel.showCamera
                ) {
                    viewModel.onPhotoCaptured()
                }
            }
            .sheet(isPresented: $viewModel.showMessageComposer) {
                if let vc = viewModel.messageComposeVC {
                    MessageComposerView(viewController: vc)
                        .ignoresSafeArea()
                }
            }
        }
    }

    private var photoPreview: some View {
        Group {
            if let image = viewModel.capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.systemGray5))
                    .frame(height: 340)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 52))
                            Text("Tap "Take Photo" to begin")
                                .font(.subheadline)
                        }
                        .foregroundColor(.secondary)
                    }
            }
        }
        .padding(.horizontal)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                viewModel.takePhoto()
            } label: {
                Label("Take Photo", systemImage: "camera.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if viewModel.capturedImage != nil {
                Button {
                    viewModel.sendViaSMS()
                } label: {
                    Label("Send via SMS", systemImage: "message.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(.horizontal)
    }
}

#Preview {
    ContentView()
}
