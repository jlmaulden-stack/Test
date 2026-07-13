import Foundation

/// Prepares receipt photos for export by copying each into a temporary file named
/// after its PO number, so the shared file is recognizable (e.g. "0234-2-ACME-receipt.jpg")
/// rather than an opaque internal filename.
enum ReceiptExporter {
    /// Temp-file URL of one PO's receipt, or nil if it has no receipt on disk.
    static func exportURL(for po: PurchaseOrder) -> URL? {
        guard let fileName = po.receiptPhotoFileName,
              PhotoStore.fileExists(fileName: fileName) else {
            return nil
        }

        let source = PhotoStore.url(fileName: fileName)
        let safeName = po.poNumber.replacingOccurrences(of: "/", with: "-")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName)-receipt.jpg")

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Temp-file URLs for every PO that has a receipt, for a bulk export.
    static func exportURLs(for orders: [PurchaseOrder]) -> [URL] {
        orders.compactMap { exportURL(for: $0) }
    }
}
