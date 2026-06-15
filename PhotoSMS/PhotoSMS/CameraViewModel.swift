import SwiftUI
import CoreLocation
import MessageUI
import AVFoundation

@MainActor
final class CameraViewModel: NSObject, ObservableObject {
    @Published var capturedImage: UIImage?
    @Published var showCamera = false
    @Published var showMessageComposer = false
    @Published var statusMessage = ""

    var messageComposeVC: MFMessageComposeViewController?

    private let locationManager = CLLocationManager()
    private var currentLocation: CLLocation?
    private var captureTimestamp: Date?

    // MARK: - Configuration — replace with your recipient's phone number
    static let recipientPhoneNumber = "+1XXXXXXXXXX"

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    // MARK: - Camera

    func takePhoto() {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch authStatus {
        case .authorized:
            startLocationAndOpenCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.startLocationAndOpenCamera()
                    } else {
                        self?.statusMessage = "Camera access denied. Enable it in Settings > Privacy."
                    }
                }
            }
        default:
            statusMessage = "Camera access denied. Enable it in Settings > Privacy."
        }
    }

    private func startLocationAndOpenCamera() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        default:
            statusMessage = "Location unavailable — will send without coordinates."
        }
        showCamera = true
    }

    func onPhotoCaptured() {
        captureTimestamp = Date()
        locationManager.requestLocation()
        updateLocationStatus()
    }

    private func updateLocationStatus() {
        if let loc = currentLocation {
            statusMessage = String(
                format: "📍 %.5f, %.5f — ready to send",
                loc.coordinate.latitude,
                loc.coordinate.longitude
            )
        } else {
            statusMessage = "Fetching location…"
        }
    }

    // MARK: - SMS

    func sendViaSMS() {
        guard MFMessageComposeViewController.canSendText() else {
            statusMessage = "SMS is not available on this device."
            return
        }
        guard let image = capturedImage else { return }

        let vc = MFMessageComposeViewController()
        vc.recipients = [Self.recipientPhoneNumber]
        vc.body = buildMessageBody(timestamp: captureTimestamp ?? Date())
        vc.messageComposeDelegate = self

        if let jpeg = image.jpegData(compressionQuality: 0.8) {
            vc.addAttachmentData(jpeg, typeIdentifier: "image/jpeg", filename: "photo.jpg")
        }

        messageComposeVC = vc
        showMessageComposer = true
    }

    private func buildMessageBody(timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .long

        var body = "📸 Captured: \(formatter.string(from: timestamp))"

        if let loc = currentLocation {
            let lat = loc.coordinate.latitude
            let lon = loc.coordinate.longitude
            body += "\n📍 \(String(format: "%.5f", lat)), \(String(format: "%.5f", lon))"
            body += "\n🗺 https://maps.apple.com/?q=\(lat),\(lon)"
        } else {
            body += "\n📍 Location unavailable"
        }

        return body
    }
}

// MARK: - CLLocationManagerDelegate

extension CameraViewModel: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in
            self?.currentLocation = location
            if self?.capturedImage != nil {
                self?.updateLocationStatus()
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            if self?.currentLocation == nil {
                self?.statusMessage = "Location unavailable."
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            default:
                break
            }
        }
    }
}

// MARK: - MFMessageComposeViewControllerDelegate

extension CameraViewModel: MFMessageComposeViewControllerDelegate {
    nonisolated func messageComposeViewController(
        _ controller: MFMessageComposeViewController,
        didFinishWith result: MessageComposeResult
    ) {
        Task { @MainActor [weak self] in
            self?.showMessageComposer = false
            self?.messageComposeVC = nil
            switch result {
            case .sent:
                self?.statusMessage = "✅ Message sent!"
                self?.capturedImage = nil
                self?.captureTimestamp = nil
            case .cancelled:
                self?.statusMessage = "Message cancelled."
            case .failed:
                self?.statusMessage = "❌ Failed to send message."
            @unknown default:
                break
            }
        }
    }
}
