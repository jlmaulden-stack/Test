import Foundation

/// Prepares receipt photos for export by copying each into a temporary file named
/// after its PO number, so shared files are recognizable (e.g. "0234-2-ACME-receipt-1.jpg")
/// rather than opaque internal filenames.
enum ReceiptExporter {
    /// Temp-file URLs for every receipt photo on one PO. A receipt with several photos
    /// numbers them "-receipt-1-2", so pages stay grouped and in order.
    static func exportURLs(for po: PurchaseOrder) -> [URL] {
        let receipts = po.receipts
        return receipts.enumerated().flatMap { index, receipt -> [URL] in
            receipt.photoFileNames.enumerated().compactMap { page, fileName in
                exportURL(
                    fileName: fileName,
                    poNumber: po.poNumber,
                    label: label(receiptIndex: index, receiptCount: receipts.count,
                                 page: page, pageCount: receipt.photoFileNames.count)
                )
            }
        }
    }

    /// Temp-file URLs for every receipt across every PO, for a bulk export.
    static func exportURLs(forAll orders: [PurchaseOrder]) -> [URL] {
        orders.flatMap { exportURLs(for: $0) }
    }

    private static func label(receiptIndex: Int, receiptCount: Int, page: Int, pageCount: Int) -> String {
        var suffix = receiptCount > 1 ? "-receipt-\(receiptIndex + 1)" : "-receipt"
        if pageCount > 1 {
            suffix += "-\(page + 1)"
        }
        return suffix
    }

    private static func exportURL(fileName: String, poNumber: String, label: String) -> URL? {
        guard PhotoStore.fileExists(fileName: fileName) else { return nil }

        let source = PhotoStore.url(fileName: fileName)
        let safeName = poNumber.replacingOccurrences(of: "/", with: "-")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName)\(label).jpg")

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
