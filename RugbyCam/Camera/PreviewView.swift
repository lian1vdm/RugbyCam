import AVFoundation
import SwiftUI
import UIKit

/// Shows the live camera picture, fitted inside the screen (never cropped).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // The layer is always a preview layer because of layerClass above.
        return layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The app only runs in landscape with the charging port on the right,
        // which is the camera sensor's own orientation.
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
    }
}

/// The part of a view that the 16:9 picture covers when it is fitted inside.
enum VideoLayout {
    static func videoRect(in size: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        return AVMakeRect(aspectRatio: CGSize(width: 16.0, height: 9.0), insideRect: bounds)
    }
}
