import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Called with 0 (landscape right) or 180 (landscape left) as the screen turns, for the recording.
    var onLandscapeRotation: ((CGFloat) -> Void)?

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.onLandscapeRotation = onLandscapeRotation
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
        uiView.onLandscapeRotation = onLandscapeRotation
        uiView.applyRotation()
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onLandscapeRotation: ((CGFloat) -> Void)?
    private var geometryObservation: NSKeyValueObservation?

    override func layoutSubviews() {
        super.layoutSubviews()
        applyRotation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Turning the phone from one landscape to the other keeps the view's size, so no layout pass
        // runs; watch the scene's orientation itself.
        geometryObservation = window?.windowScene?.observe(\.effectiveGeometry) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyRotation() }
        }
        applyRotation()
    }

    /// The preview layer otherwise keeps the portrait default (90 degrees), which shows the picture
    /// turned a quarter inside the landscape screen. Match it to how the screen is turned.
    func applyRotation() {
        guard let orientation = window?.windowScene?.interfaceOrientation else { return }
        let angle: CGFloat = switch orientation {
        case .landscapeRight: 0
        case .landscapeLeft: 180
        case .portraitUpsideDown: 270
        default: 90
        }
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle),
           connection.videoRotationAngle != angle {
            connection.videoRotationAngle = angle
        }
        if angle == 0 || angle == 180 { onLandscapeRotation?(angle) }
    }
}
