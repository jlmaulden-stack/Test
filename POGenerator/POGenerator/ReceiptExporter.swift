import Foundation

/// Prepares receipt photos for export by copying each into a temporary file named
/// after its PO number, so shared files are recognizable (e.g. "0234-2-ACME-receipt-1.jpg")
/// rather than opaque internal filenames.
enum ReceiptExporter {
    /// Temp-file URLs for every receipt on one PO.
    static func exportURLs(for po: PurchaseOrder) -> [URL] {
        let receipts = po.receipts
        return receipts.enumerated().compactMap { index, receipt in
            exportURL(receipt, poNumber: po.poNumber, index: index, total: receipts.count)
        }
    }

    /// Temp-file URLs for every receipt across every PO, for a bulk export.
    static func exportURLs(forAll orders: [PurchaseOrder]) -> [URL] {
        orders.flatMap { exportURLs(for: $0) }
    }

    private static func exportURL(_ receipt: Receipt, poNumber: String, index: Int, total: Int) -> URL? {
        guard PhotoStore.fileExists(fileName: receipt.photoFileName) else { return nil }

        let source = PhotoStore.url(fileName: receipt.photoFileName)
        let safeName = poNumber.replacingOccurrences(of: "/", with: "-")
        let suffix = total > 1 ? "-receipt-\(index + 1)" : "-receipt"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName)\(suffix).jpg")

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
}
