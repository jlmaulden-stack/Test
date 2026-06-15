import SwiftUI
import MessageUI

struct MessageComposerView: UIViewControllerRepresentable {
    let viewController: MFMessageComposeViewController

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        viewController
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}
}
