import SwiftUI
import UIKit

// Copy of the picture editor in RugbyCam/UI/TrainingView.swift (the iPad app is a separate app).

// MARK: - The zoomable picture with the boxes

/// Asks the picture to zoom. A new serial number makes it zoom again.
struct ZoomCommand: Equatable {
    enum Kind: Equatable {
        case whole
        case around(NBox)
    }
    var kind: Kind
    var serial: Int
}

final class BoxEditorScrollView: UIScrollView {
    var onSizeChange: (() -> Void)?
    private var lastSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            onSizeChange?()
        }
    }
}

/// The picture at full resolution in a scroll view: pinch to zoom, two fingers
/// to move, one finger to draw, move or resize the box.
struct BoxEditor: UIViewRepresentable {
    let image: CGImage
    let imageID: String
    let guess: NBox?
    @Binding var box: NBox?
    let tapSize: Double
    let zoom: ZoomCommand

    func makeCoordinator() -> Coordinator {
        return Coordinator()
    }

    func makeUIView(context: Context) -> BoxEditorScrollView {
        let coordinator = context.coordinator
        coordinator.parent = self
        let scrollView = BoxEditorScrollView()
        scrollView.delegate = coordinator
        scrollView.backgroundColor = .black
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bouncesZoom = true
        scrollView.delaysContentTouches = false
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        coordinator.scrollView = scrollView

        scrollView.addSubview(coordinator.content)
        coordinator.content.addSubview(coordinator.imageView)
        coordinator.content.layer.addSublayer(coordinator.guessLayer)
        coordinator.content.layer.addSublayer(coordinator.boxLayer)
        coordinator.content.layer.addSublayer(coordinator.handleLayer)

        let draw = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.drag(_:)))
        draw.maximumNumberOfTouches = 1
        coordinator.content.addGestureRecognizer(draw)
        coordinator.drawGesture = draw

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        coordinator.content.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: doubleTap)
        coordinator.content.addGestureRecognizer(tap)

        scrollView.onSizeChange = { [weak coordinator] in
            coordinator?.sizeChanged(reset: false)
        }
        return scrollView
    }

    func updateUIView(_ scrollView: BoxEditorScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.show(image, id: imageID)
        if zoom.serial != coordinator.zoomSerial {
            coordinator.zoomSerial = zoom.serial
            coordinator.pendingZoom = zoom.kind
            coordinator.applyPendingZoom()
        }
        coordinator.redraw()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: BoxEditor!
        weak var scrollView: BoxEditorScrollView?
        weak var drawGesture: UIPanGestureRecognizer?
        let content = UIView()
        let imageView = UIImageView()
        let guessLayer = CAShapeLayer()
        let boxLayer = CAShapeLayer()
        let handleLayer = CAShapeLayer()
        var zoomSerial = -1
        var pendingZoom: ZoomCommand.Kind?

        private var imageID: String?
        private var imageSize = CGSize(width: 1.0, height: 1.0)

        private enum DragMode {
            case create(CGPoint)               // from this corner to the finger
            case resize(CGPoint)               // the opposite corner stays put
            case move(CGRect, CGPoint)         // box and finger at the start
        }
        private var mode: DragMode?
        private var boxBeforeDrag: NBox?

        override init() {
            super.init()
            imageView.contentMode = .scaleToFill
            guessLayer.fillColor = nil
            guessLayer.strokeColor = UIColor.systemYellow.cgColor
            boxLayer.fillColor = UIColor.systemGreen.withAlphaComponent(0.15).cgColor
            boxLayer.strokeColor = UIColor.systemGreen.cgColor
            handleLayer.fillColor = UIColor.white.cgColor
            handleLayer.strokeColor = UIColor.systemGreen.cgColor
        }

        // MARK: Picture and zoom

        func show(_ image: CGImage, id: String) {
            guard id != imageID, let scrollView = scrollView else { return }
            imageID = id
            imageView.image = UIImage(cgImage: image)
            imageSize = CGSize(width: max(image.width, 1), height: max(image.height, 1))
            scrollView.minimumZoomScale = 1.0
            scrollView.zoomScale = 1.0
            content.frame = CGRect(origin: .zero, size: imageSize)
            imageView.frame = content.bounds
            for layer in [guessLayer, boxLayer, handleLayer] {
                layer.frame = content.bounds
            }
            scrollView.contentSize = imageSize
            sizeChanged(reset: true)
        }

        func sizeChanged(reset: Bool) {
            guard let scrollView = scrollView, imageID != nil,
                  scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
            let wasWhole = scrollView.zoomScale <= scrollView.minimumZoomScale + 0.0001
            let fit = min(scrollView.bounds.width / imageSize.width, scrollView.bounds.height / imageSize.height)
            scrollView.minimumZoomScale = fit
            // Up to 3 screen points per picture pixel: enough to see a far-away ball.
            scrollView.maximumZoomScale = max(fit * 2.0, 3.0)
            if reset || wasWhole || scrollView.zoomScale < fit {
                scrollView.zoomScale = fit
            }
            centre()
            applyPendingZoom()
            redraw()
        }

        func applyPendingZoom() {
            guard let kind = pendingZoom, let scrollView = scrollView, imageID != nil,
                  scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
            pendingZoom = nil
            switch kind {
            case .whole:
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            case .around(let target):
                // Show the box with plenty of picture around it.
                let width = max(target.w * 10.0, 0.12) * imageSize.width
                let height = width * scrollView.bounds.height / scrollView.bounds.width
                let centre = CGPoint(x: (target.x + target.w / 2.0) * imageSize.width,
                                     y: (target.y + target.h / 2.0) * imageSize.height)
                scrollView.zoom(to: CGRect(x: centre.x - width / 2.0, y: centre.y - height / 2.0,
                                           width: width, height: height), animated: true)
            }
        }

        /// Keeps the picture in the middle when it is smaller than the screen.
        private func centre() {
            guard let scrollView = scrollView else { return }
            let dx = max((scrollView.bounds.width - content.frame.width) / 2.0, 0.0)
            let dy = max((scrollView.bounds.height - content.frame.height) / 2.0, 0.0)
            scrollView.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return content
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centre()
            redraw()
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            cancelDrag()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            cancelDrag()
        }

        // MARK: Drawing

        private var scale: CGFloat {
            return max(scrollView?.zoomScale ?? 1.0, 0.0001)
        }

        private func rect(for box: NBox) -> CGRect {
            return CGRect(x: box.x * imageSize.width, y: box.y * imageSize.height,
                          width: box.w * imageSize.width, height: box.h * imageSize.height)
        }

        /// Top left, top right, bottom left, bottom right.
        private func corners(of rect: CGRect) -> [CGPoint] {
            return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        }

        func redraw() {
            let s = scale
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Lines keep the same thickness on screen at every zoom.
            guessLayer.lineWidth = 1.5 / s
            guessLayer.lineDashPattern = [NSNumber(value: Double(6.0 / s)), NSNumber(value: Double(4.0 / s))]
            if let modelGuess = parent?.guess {
                let outer = rect(for: modelGuess).insetBy(dx: -3.0 / s, dy: -3.0 / s)
                guessLayer.path = UIBezierPath(rect: outer).cgPath
            } else {
                guessLayer.path = nil
            }
            boxLayer.lineWidth = 1.5 / s
            handleLayer.lineWidth = 1.5 / s
            if let current = parent?.box {
                let r = rect(for: current)
                boxLayer.path = UIBezierPath(rect: r).cgPath
                let handles = UIBezierPath()
                let radius = 5.0 / s
                for corner in corners(of: r) {
                    handles.append(UIBezierPath(ovalIn: CGRect(x: corner.x - radius, y: corner.y - radius,
                                                               width: radius * 2.0, height: radius * 2.0)))
                }
                handleLayer.path = handles.cgPath
            } else {
                boxLayer.path = nil
                handleLayer.path = nil
            }
            CATransaction.commit()
        }

        // MARK: Touches

        private func clamped(_ point: CGPoint) -> CGPoint {
            return CGPoint(x: min(max(point.x, 0.0), imageSize.width),
                           y: min(max(point.y, 0.0), imageSize.height))
        }

        private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            return hypot(a.x - b.x, a.y - b.y)
        }

        @objc func drag(_ gesture: UIPanGestureRecognizer) {
            let point = clamped(gesture.location(in: content))
            switch gesture.state {
            case .began:
                let moved = gesture.translation(in: content)
                let start = clamped(CGPoint(x: point.x - moved.x, y: point.y - moved.y))
                boxBeforeDrag = parent.box
                let reach = 30.0 / scale
                mode = .create(start)
                if let current = parent.box {
                    let r = rect(for: current)
                    let list = corners(of: r)
                    let nearest = list.indices.min { distance(list[$0], start) < distance(list[$1], start) } ?? 0
                    if distance(list[nearest], start) <= reach {
                        mode = .resize(list[3 - nearest])
                    } else if r.insetBy(dx: -reach / 2.0, dy: -reach / 2.0).contains(start) {
                        mode = .move(r, start)
                    }
                }
                update(point)
            case .changed:
                update(point)
            default:
                mode = nil
                boxBeforeDrag = nil
            }
        }

        private func update(_ point: CGPoint) {
            guard let mode = mode else { return }
            switch mode {
            case .create(let anchor), .resize(let anchor):
                set(CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)))
            case .move(let start, let finger):
                var moved = start.offsetBy(dx: point.x - finger.x, dy: point.y - finger.y)
                moved.origin.x = min(max(moved.minX, 0.0), imageSize.width - moved.width)
                moved.origin.y = min(max(moved.minY, 0.0), imageSize.height - moved.height)
                set(moved)
            }
        }

        /// A second finger came down: that was the start of a pinch, not a box.
        private func cancelDrag() {
            guard mode != nil else { return }
            mode = nil
            parent.box = boxBeforeDrag
            boxBeforeDrag = nil
            drawGesture?.isEnabled = false
            drawGesture?.isEnabled = true
            redraw()
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            let point = clamped(gesture.location(in: content))
            let width: CGFloat
            let height: CGFloat
            if let current = parent.box {
                let r = rect(for: current)
                width = r.width
                height = r.height
            } else {
                width = CGFloat(parent.tapSize) * imageSize.width
                height = width * 0.75          // a rugby ball is a little wider than tall
            }
            set(CGRect(x: point.x - width / 2.0, y: point.y - height / 2.0, width: width, height: height))
        }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale * 1.5 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }
            let target = min(scrollView.minimumZoomScale * 5.0, scrollView.maximumZoomScale)
            let point = gesture.location(in: content)
            let width = scrollView.bounds.width / target
            let height = scrollView.bounds.height / target
            scrollView.zoom(to: CGRect(x: point.x - width / 2.0, y: point.y - height / 2.0,
                                       width: width, height: height), animated: true)
        }

        /// Stores a box given in picture pixels.
        private func set(_ rect: CGRect) {
            var r = rect.standardized
            r.size.width = min(max(r.width, 2.0), imageSize.width)
            r.size.height = min(max(r.height, 2.0), imageSize.height)
            r.origin.x = min(max(r.minX, 0.0), imageSize.width - r.width)
            r.origin.y = min(max(r.minY, 0.0), imageSize.height - r.height)
            parent.box = NBox(x: Double(r.minX / imageSize.width), y: Double(r.minY / imageSize.height),
                              w: Double(r.width / imageSize.width), h: Double(r.height / imageSize.height))
            redraw()
        }
    }
}
