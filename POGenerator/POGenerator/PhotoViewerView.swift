import SwiftUI
import UIKit

/// Full-screen viewer for an attached photo, with share (which also covers saving to
/// Photos or Files) and an optional delete. Used for both submission photos and receipts.
struct PhotoViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let fileName: String
    let title: String
    /// Nil when the photo can't be removed from this context (e.g. a receipt, which is
    /// deleted along with its amount from the Receipts section instead).
    var onDelete: (() -> Void)?

    @State private var showDeleteConfirmation = false
    @State private var exportPayload: ExportPayload?

    private var image: UIImage? {
        PhotoStore.loadImage(fileName: fileName)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if let image {
                    // Pinch/pan would be nice, but scaledToFit keeps the whole photo
                    // visible which is what matters for reading a receipt.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 40))
                            .foregroundColor(Theme.steel)
                        Text("Photo Unavailable")
                            .font(.headline)
                        Text("This photo hasn't downloaded to this device yet. Pull to refresh History and try again.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            exportPayload = ExportPayload(urls: [PhotoStore.url(fileName: fileName)])
                        } label: {
                            Label("Share / Save", systemImage: "square.and.arrow.up")
                        }
                        .disabled(image == nil)

                        if onDelete != nil {
                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete Photo", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $exportPayload) { payload in
                ShareSheet(items: payload.urls)
            }
            .confirmationDialog(
                "Delete this photo?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Photo", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the photo from the PO for everyone. It can't be undone.")
            }
        }
        .preferredColorScheme(.dark)
    }
}
