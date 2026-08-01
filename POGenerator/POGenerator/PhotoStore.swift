import UIKit

/// Saves PO photo attachments as JPEG files in the app's Documents directory.
/// Only the file name is stored on the PurchaseOrder record.
enum PhotoStore {
    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Saves a PO submission photo under a fresh unique name, returning that name.
    static func savePhoto(_ image: UIImage) -> String? {
        save(image, fileName: "\(UUID().uuidString).jpg")
    }

    /// Saves a receipt photo under a distinct name keyed to the receipt's id so it
    /// never collides with submission photos or other receipts.
    static func saveReceipt(_ image: UIImage, id: String) -> String? {
        save(image, fileName: "receipt-\(id).jpg")
    }

    private static func save(_ image: UIImage, fileName: String) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.7) else { return nil }
        let url = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    static func loadImage(fileName: String) -> UIImage? {
        guard let data = try? Data(contentsOf: url(fileName: fileName)) else { return nil }
        return UIImage(data: data)
    }

    static func url(fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func fileExists(fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(fileName: fileName).path)
    }

    /// Writes raw image data (e.g. a downloaded CloudKit asset) under the given name,
    /// skipping the write if the file already exists (photos are immutable).
    static func writeIfMissing(_ data: Data, fileName: String) {
        guard !fileExists(fileName: fileName) else { return }
        try? data.write(to: url(fileName: fileName), options: .atomic)
    }

    static func delete(fileName: String) {
        try? FileManager.default.removeItem(at: url(fileName: fileName))
    }
}
