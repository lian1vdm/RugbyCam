import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A video picked from Photos, copied into the app's temporary folder.
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let copy = PickedVideo.temporaryCopyURL(extension: received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedVideo(url: copy)
        }
    }

    static func temporaryCopyURL(extension ext: String) -> URL {
        let name = "import-\(UUID().uuidString).\(ext.isEmpty ? "mov" : ext)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }
}

/// Settings > Training: import videos, check pictures, send them to the PC.
struct TrainingView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: TrainingStore

    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var loadingVideo = false
    @State private var exportURL: URL?
    @State private var exportIDs: [String] = []
    @State private var packing = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("To check")
                    Spacer()
                    Text("\(store.pending.count)").foregroundColor(.secondary)
                }
                HStack {
                    Text("Checked, not sent yet")
                    Spacer()
                    Text("\(store.checked.count)").foregroundColor(.secondary)
                }
                HStack {
                    Text("Already sent to the PC")
                    Spacer()
                    Text("\(store.exported.count)").foregroundColor(.secondary)
                }
                NavigationLink {
                    ReviewView(store: store)
                } label: {
                    Label("Check pictures", systemImage: "checkmark.circle")
                }
                .disabled(store.pending.isEmpty)
            } header: {
                Text("Training pictures")
            } footer: {
                Text("For each picture you mark where the ball is, or that there is none. The pictures where your model was unsure come first, because they teach it the most.")
            }

            Section {
                PhotosPicker(selection: $photoItem, matching: .videos) {
                    Label("Import a video from Photos", systemImage: "photo.on.rectangle")
                }
                .disabled(store.isScanning || loadingVideo)
                Button {
                    showFileImporter = true
                } label: {
                    Label("Import a video from Files", systemImage: "folder")
                }
                .disabled(store.isScanning || loadingVideo)
                Stepper(value: $model.settings.importKeep, in: 20...200, step: 10) {
                    Text("Pictures to keep per video: \(model.settings.importKeep)")
                }
                Picker("Look at the video every", selection: $model.settings.importEvery) {
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("5 s").tag(5.0)
                }
                if loadingVideo {
                    HStack {
                        ProgressView()
                        Text("Copying the video")
                    }
                }
                if let text = store.scanText {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: store.scanFraction)
                        Text(text).font(.footnote).foregroundColor(.secondary)
                        Button("Stop", role: .destructive) {
                            store.cancelImport()
                        }
                    }
                }
                if let message = store.message {
                    Text(message).font(.footnote)
                }
            } header: {
                Text("Import a video")
            } footer: {
                Text("Your ball model looks through the video and keeps the pictures worth checking. A full match takes several minutes; keep the app open meanwhile.")
            }

            Section {
                Toggle("While recording, save moments the ball is lost", isOn: $model.settings.saveHardFrames)
            } footer: {
                Text("While you record, a picture is kept at most every 4 seconds when players are in view but the ball is not found. They appear above under \"To check\".")
            }

            Section {
                Button {
                    pack()
                } label: {
                    if packing {
                        HStack {
                            ProgressView()
                            Text("Packing")
                        }
                    } else {
                        Label("Send checked pictures to the PC", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(store.checked.isEmpty || packing)
                Button("Delete pictures already sent", role: .destructive) {
                    store.deleteExported()
                }
                .disabled(store.exported.isEmpty)
            } header: {
                Text("Send to the PC")
            } footer: {
                Text("This makes one zip file. Choose \"Save to Files\" and then iCloud Drive. On the PC, run import_phone_training.py: it adds the pictures to your dataset and trains the model again.")
            }
        }
        .navigationTitle("Training")
        .onChange(of: photoItem) { item in
            guard let item = item else { return }
            loadingVideo = true
            Task {
                let video = try? await item.loadTransferable(type: PickedVideo.self)
                await MainActor.run {
                    loadingVideo = false
                    photoItem = nil
                    if let video = video {
                        startImport(video.url)
                    } else {
                        store.message = "The video could not be loaded from Photos."
                    }
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie, .video]) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let copy = PickedVideo.temporaryCopyURL(extension: url.pathExtension)
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    startImport(copy)
                } catch {
                    store.message = "The video could not be copied: \(error.localizedDescription)"
                }
            case .failure(let error):
                store.message = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let url = exportURL {
                ShareSheet(items: [url]) { completed in
                    if completed {
                        store.markSent(exportIDs)
                        store.message = "Sent \(exportIDs.count) pictures."
                    }
                    exportURL = nil
                }
            }
        }
    }

    private func startImport(_ url: URL) {
        store.importVideo(url, every: model.settings.importEvery, keep: model.settings.importKeep)
    }

    private func pack() {
        packing = true
        let ids = store.checked.map { $0.id }
        store.makeExport { result in
            packing = false
            switch result {
            case .success(let url):
                exportIDs = ids
                exportURL = url
            case .failure(let error):
                store.message = error.localizedDescription
            }
        }
    }
}

/// The iOS share sheet ("Save to Files", AirDrop, ...).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let done: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            done(completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
    }
}

// MARK: - Checking one picture after another

struct ReviewView: View {
    @ObservedObject var store: TrainingStore
    @Environment(\.dismiss) private var dismiss

    @State private var itemID: String?
    @State private var picture: CGImage?
    @State private var guess: NBox?                 // the model's guess (yellow, dashed)
    @State private var guessConfidence = 0.0
    @State private var box: NBox?                   // your box (green)
    @State private var tapSize = 0.012              // width of a box made by a tap
    @State private var zoom = ZoomCommand(kind: .whole, serial: 0)

    var body: some View {
        VStack(spacing: 8) {
            if let image = picture, let id = itemID {
                statusLine
                BoxEditor(image: image, imageID: id, guess: guess, box: $box,
                          tapSize: tapSize, zoom: zoom)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("One finger: draw a box, or drag it and its corners. Tap: put the box there. Pinch: zoom. Two fingers: move the picture. Double-tap: zoom in or out.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                viewButtons
                answerButtons
            } else if store.pending.isEmpty {
                Spacer()
                Text("All pictures are checked.").font(.headline)
                Button("Back") { dismiss() }
                Spacer()
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .navigationTitle("\(store.pending.count) left")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadNext() }
    }

    // MARK: Parts of the screen

    private var statusLine: some View {
        HStack(spacing: 8) {
            if guess != nil {
                Image(systemName: guessConfidence < 0.55 ? "questionmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundColor(guessConfidence < 0.55 ? .orange : .green)
                Text(String(format: "Model's guess (yellow, dashed): %.0f %% sure", guessConfidence * 100.0)
                     + (guessConfidence < 0.55 ? ". Check it closely." : "."))
            } else {
                Image(systemName: "eye.slash")
                    .foregroundColor(.orange)
                Text("The model found no ball. Draw a box if you can see one.")
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
    }

    private var viewButtons: some View {
        HStack(spacing: 8) {
            Button {
                newZoom(.whole)
            } label: {
                Label("Whole", systemImage: "arrow.down.right.and.arrow.up.left")
                    .frame(maxWidth: .infinity)
            }
            Button {
                if let target = box ?? guess {
                    newZoom(.around(target))
                }
            } label: {
                Label("Zoom to box", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .disabled(box == nil && guess == nil)
            if let modelGuess = guess {
                Button {
                    box = modelGuess
                    newZoom(.around(modelGuess))
                } label: {
                    Label("Edit guess", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
            }
            if box != nil {
                Button(role: .destructive) {
                    box = nil
                } label: {
                    Label("Clear", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .buttonStyle(.bordered)
        .font(.footnote)
        .labelStyle(.titleAndIcon)
    }

    private var answerButtons: some View {
        HStack(spacing: 8) {
            Button {
                finish(.noBall)
            } label: {
                Label("No ball", systemImage: "circle.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button {
                discardCurrent()
            } label: {
                Label("Throw away", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            Button {
                if let answer = box ?? guess {
                    finish(.ball(answer))
                }
            } label: {
                Label(box == nil && guess != nil ? "Guess is right" : "Ball is here",
                      systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(box == nil && guess == nil)
        }
        .font(.subheadline)
    }

    // MARK: Moving on

    private func newZoom(_ kind: ZoomCommand.Kind) {
        zoom = ZoomCommand(kind: kind, serial: zoom.serial + 1)
    }

    private func finish(_ label: TrainingLabel) {
        guard let id = itemID else { return }
        if case .ball(let answer) = label {
            // The next ball is probably about as big: a tap makes a box this size.
            tapSize = min(max(answer.w, 0.003), 0.08)
        }
        store.setLabel(label, for: id)
        loadNext()
    }

    private func discardCurrent() {
        guard let id = itemID else { return }
        store.discard(id)
        loadNext()
    }

    private func loadNext() {
        picture = nil
        box = nil
        guard let next = store.pending.first else {
            itemID = nil
            guess = nil
            return
        }
        itemID = next.id
        guess = next.guess
        guessConfidence = next.guessConfidence
        let url = store.imageURL(for: next.id)
        DispatchQueue.global(qos: .userInitiated).async {
            // Full size, so zooming in stays sharp for small, far-away balls.
            let image = TrainingStore.loadImage(at: url, maxPixels: 4096)
            DispatchQueue.main.async {
                guard itemID == next.id else { return }
                if let image = image {
                    picture = image
                    newZoom(next.guess.map { ZoomCommand.Kind.around($0) } ?? ZoomCommand.Kind.whole)
                } else {
                    store.discard(next.id)
                    loadNext()
                }
            }
        }
    }
}

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
