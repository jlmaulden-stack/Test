import SwiftUI
import UIKit

/// Identifiable payload of file URLs to share, so a share sheet can be driven from
/// `.sheet(item:)` without a retroactive URL: Identifiable conformance.
struct ExportPayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Wraps UIActivityViewController so receipts can be exported via the system share
/// sheet (save to Files/Photos, email, AirDrop, etc.).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
