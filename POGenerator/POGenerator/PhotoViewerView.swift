import SwiftUI
import UIKit

/// Full-screen viewer for an attached photo, with share (which also covers saving to
/// Photos or Files) and an optional delete. Used for both submission photos and receipts.
struct PhotoViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let fileName: String
    let title: String
    /// Nil when the photo can't be removed from this context. Deleting the last photo
    /// off a receipt takes the receipt with it, which the caller handles.
    var onDelete: (() -> Void)?

    @State private var showDeleteConfirmation = false
    @State private var exportPayload: ExportPayload?

    // Zoom/pan state. `committed*` holds the value from the end of the last gesture so
    // a new pinch or drag continues from there instead of snapping back to 1x.
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private static let maxScale: CGFloat = 6
    private static let doubleTapScale: CGFloat = 3

    private var image: UIImage? {
        PhotoStore.loadImage(fileName: fileName)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if let image {
                    // Pinch to zoom, drag to pan, double-tap to toggle -- reading the
                    // line items on a receipt photo needs all three.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(panGesture)
                        .simultaneousGesture(zoomGesture)
                        .onTapGesture(count: 2) { toggleZoom() }
                        .clipped()
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
            .overlay(alignment: .bottom) {
                if scale > 1 {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { resetZoom() }
                    } label: {
                        Label("\(zoomLabel) — Reset", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.caption)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(.bottom, 24)
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

    private var zoomLabel: String {
        String(format: "%.1fx", scale)
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(committedScale * value, 1), Self.maxScale)
            }
            .onEnded { _ in
                committedScale = scale
                if scale <= 1 {
                    withAnimation(.easeOut(duration: 0.2)) { resetZoom() }
                }
            }
    }

    /// Panning only applies while zoomed in -- at 1x the whole photo is already visible.
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                committedOffset = offset
            }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if scale > 1 {
                resetZoom()
            } else {
                scale = Self.doubleTapScale
                committedScale = scale
            }
        }
    }

    private func resetZoom() {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
    }
}
