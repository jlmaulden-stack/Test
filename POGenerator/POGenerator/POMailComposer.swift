import MessageUI
import SwiftUI
import UIKit

/// Where fulfilled-PO summaries are sent.
enum POMail {
    static let recipient = "hannah@insightelectrical.net"

    static var canSend: Bool { MFMailComposeViewController.canSendMail() }

    static func subject(for po: PurchaseOrder) -> String {
        "PO \(po.poNumber) — \(po.customerName) — \(po.status.label)"
    }

    /// Plain-text summary of everything recorded against the PO.
    static func body(for po: PurchaseOrder) -> String {
        var lines: [String] = []

        lines.append("PURCHASE ORDER \(po.poNumber)")
        lines.append("")
        lines.append("Customer:     \(po.customerName)")
        lines.append("Job Number:   \(po.jobNumber)")
        lines.append("Requested by: \(po.createdByName)")
        lines.append("Requested:    \(format(po.createdAt))")

        if let approver = po.approvedByName {
            let suffix = po.wasSelfApproved ? " (self-approved)" : ""
            lines.append("Approved by:  \(approver)\(suffix)")
        }
        if let approvedAt = po.approvedAt {
            lines.append("Approved:     \(format(approvedAt))")
        }

        lines.append("Status:       \(po.status.label)")
        if let by = po.statusUpdatedByName, let at = po.statusUpdatedAt {
            lines.append("Updated by:   \(by) on \(format(at))")
        }

        if !po.details.isEmpty {
            lines.append("")
            lines.append("MATERIALS REQUESTED")
            lines.append(po.details)
        }

        if !po.fulfillmentNotes.isEmpty {
            lines.append("")
            lines.append("FULFILLMENT NOTES")
            lines.append(po.fulfillmentNotes)
        }

        lines.append("")
        lines.append("RECEIPTS (\(po.receipts.count))")
        if po.receipts.isEmpty {
            lines.append("None attached.")
        } else {
            for (index, receipt) in po.receipts.enumerated() {
                let amount = receipt.amount.map { currency($0) } ?? "no amount entered"
                lines.append("  \(index + 1). \(amount)")
            }
            if let total = po.totalAmount {
                lines.append("")
                lines.append("TOTAL: \(currency(total))")
            }
        }

        let photoCount = po.photoFileNames.count
        let receiptPhotoCount = po.receipts.count
        lines.append("")
        lines.append("Attached: \(photoCount) request photo(s), \(receiptPhotoCount) receipt photo(s).")
        lines.append("")
        lines.append("Sent from PO Generator.")

        return lines.joined(separator: "\n")
    }

    /// Request photos and receipt photos, named so they're identifiable in the mail.
    static func attachments(for po: PurchaseOrder) -> [(data: Data, fileName: String)] {
        var result: [(Data, String)] = []
        let safeNumber = po.poNumber.replacingOccurrences(of: "/", with: "-")

        for (index, name) in po.photoFileNames.enumerated() {
            if let data = try? Data(contentsOf: PhotoStore.url(fileName: name)) {
                result.append((data, "\(safeNumber)-request-\(index + 1).jpg"))
            }
        }
        for (index, receipt) in po.receipts.enumerated() {
            if let data = try? Data(contentsOf: PhotoStore.url(fileName: receipt.photoFileName)) {
                result.append((data, "\(safeNumber)-receipt-\(index + 1).jpg"))
            }
        }
        return result
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }
}

/// Wraps MFMailComposeViewController. iOS gives no way to send mail silently, so this
/// presents the Mail composer pre-filled -- the user taps Send.
struct POMailComposeView: UIViewControllerRepresentable {
    let po: PurchaseOrder
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([POMail.recipient])
        controller.setSubject(POMail.subject(for: po))
        controller.setMessageBody(POMail.body(for: po), isHTML: false)
        for attachment in POMail.attachments(for: po) {
            // octet-stream rather than image/jpeg so mail clients show these as file
            // attachments to download instead of previewing them inline in the message.
            controller.addAttachmentData(attachment.data, mimeType: "application/octet-stream", fileName: attachment.fileName)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let parent: POMailComposeView

        init(_ parent: POMailComposeView) {
            self.parent = parent
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            parent.dismiss()
        }
    }
}
