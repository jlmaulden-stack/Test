import UIKit

/// Saves PO photo attachments as JPEG files in the app's Documents directory.
/// Only the file name is stored on the PurchaseOrder record.
enum PhotoStore {
    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func save(_ image: UIImage, forPOID id: String) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.7) else { return nil }
        let fileName = "\(id).jpg"
        let url = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    static func loadImage(fileName: String) -> UIImage? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func delete(fileName: String) {
        let url = directory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }
}
