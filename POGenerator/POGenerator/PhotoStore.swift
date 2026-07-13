import UIKit

/// Saves PO photo attachments as JPEG files in the app's Documents directory.
/// Only the file name is stored on the PurchaseOrder record.
enum PhotoStore {
    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func save(_ image: UIImage, forPOID id: String) -> String? {
        save(image, fileName: "\(id).jpg")
    }

    /// Saves a receipt photo under a distinct name so it never collides with the
    /// PO's main attachment photo.
    static func saveReceipt(_ image: UIImage, forPOID id: String) -> String? {
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

    static func delete(fileName: String) {
        try? FileManager.default.removeItem(at: url(fileName: fileName))
    }
}
