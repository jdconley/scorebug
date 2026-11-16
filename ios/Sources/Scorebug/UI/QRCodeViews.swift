import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Live QR scanner. Calls `onCode` with each new decoded string; the caller decides what it means.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) { controller.onCode = onCode }

    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        AVCaptureDevice.default(for: .video) != nil
        #endif
    }

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Void = { _ in }
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var last: String?
        private let queue = DispatchQueue(label: "scorebug.qr-scanner")

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                self?.queue.async { self?.configure() }
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.beginConfiguration()
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { session.commitConfiguration(); return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            session.startRunning()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let layer = AVCaptureVideoPreviewLayer(session: session)
                layer.videoGravity = .resizeAspectFill
                layer.frame = view.bounds
                view.layer.addSublayer(layer)
                preview = layer
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = session
            queue.async { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, code != last else { return }
            last = code
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode(code)
        }
    }
}

/// Scanner framed with corner marks, or a plain placeholder where there is no camera.
struct ScannerBox: View {
    var onCode: (String) -> Void
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.surface)
            if QRScannerView.isAvailable {
                QRScannerView(onCode: onCode).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 40)).foregroundStyle(Theme.secondary)
                    Text("Camera not available here").font(.footnote).foregroundStyle(Theme.secondary)
                }
            }
            CornerMarks().stroke(Theme.text, style: StrokeStyle(lineWidth: 4, lineCap: .round)).padding(36)
                .accessibilityHidden(true)
        }
        .frame(width: 260, height: 260)
        .accessibilityLabel("QR code scanner")
    }
}

private struct CornerMarks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let l: CGFloat = 40
        for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                               (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            path.move(to: CGPoint(x: x, y: y + dy * l))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + dx * l, y: y))
        }
        return path
    }
}

/// A crisp QR code for an invite link.
struct QRCodeImage: View {
    let text: String
    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                .accessibilityLabel("QR code for the invite link")
        } else {
            Color.clear
        }
    }

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
