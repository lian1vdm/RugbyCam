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
    @State private var picture: CGImage?          // the whole picture
    @State private var box: NBox?
    @State private var boxAspect = 1.0             // height / width, in picture fractions
    @State private var size = 0.012                // box width as a share of the picture width
    @State private var zoomed = false
    @State private var zoomCentre = NPoint(x: 0.5, y: 0.5)

    private let zoomWidth = 0.22                   // share of the picture shown when zoomed in

    var body: some View {
        VStack(spacing: 10) {
            if let image = picture {
                pictureView(image)
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
            if picture != nil {
                controls
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .navigationTitle("\(store.pending.count) left")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadNext() }
    }

    // MARK: Picture

    private var visibleRect: NBox {
        guard zoomed else { return NBox.full }
        let w = zoomWidth
        let h = zoomWidth
        let x = min(max(zoomCentre.x - w / 2.0, 0.0), 1.0 - w)
        let y = min(max(zoomCentre.y - h / 2.0, 0.0), 1.0 - h)
        return NBox(x: x, y: y, w: w, h: h)
    }

    private func pictureView(_ image: CGImage) -> some View {
        let visible = visibleRect
        let pixelWidth = Double(image.width)
        let pixelHeight = Double(image.height)
        let crop = CGRect(x: visible.x * pixelWidth, y: visible.y * pixelHeight,
                          width: visible.w * pixelWidth, height: visible.h * pixelHeight).integral
        let shown = image.cropping(to: crop) ?? image
        let aspect = CGSize(width: crop.width, height: crop.height)
        return GeometryReader { geometry in
            let frame = AVMakeRect(aspectRatio: aspect, insideRect: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                Image(decorative: shown, scale: 1.0)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                if let current = box {
                    let rect = ReviewView.place(current, visible: visible, in: frame)
                    Rectangle()
                        .stroke(Color.red, lineWidth: 2)
                        .frame(width: max(rect.width, 6), height: max(rect.height, 6))
                        .offset(x: rect.midX - max(rect.width, 6) / 2.0, y: rect.midY - max(rect.height, 6) / 2.0)
                    Circle()
                        .stroke(Color.yellow, lineWidth: 1)
                        .frame(width: max(rect.width, 6) + 24, height: max(rect.height, 6) + 24)
                        .offset(x: rect.midX - (max(rect.width, 6) + 24) / 2.0,
                                y: rect.midY - (max(rect.height, 6) + 24) / 2.0)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let fx = (Double(drag.location.x) - Double(frame.minX)) / Double(frame.width)
                let fy = (Double(drag.location.y) - Double(frame.minY)) / Double(frame.height)
                guard fx >= 0.0, fx <= 1.0, fy >= 0.0, fy <= 1.0 else { return }
                let point = NPoint(x: visible.x + fx * visible.w, y: visible.y + fy * visible.h)
                setCentre(point)
            })
        }
    }

    /// Converts a box in whole-picture fractions into screen points.
    private static func place(_ box: NBox, visible: NBox, in frame: CGRect) -> CGRect {
        let x = (box.x - visible.x) / visible.w
        let y = (box.y - visible.y) / visible.h
        return CGRect(x: Double(frame.minX) + x * Double(frame.width),
                      y: Double(frame.minY) + y * Double(frame.height),
                      width: box.w / visible.w * Double(frame.width),
                      height: box.h / visible.h * Double(frame.height))
    }

    private func setCentre(_ point: NPoint) {
        let w = size
        let h = size * boxAspect
        box = NBox(x: min(max(point.x - w / 2.0, 0.0), 1.0 - w),
                   y: min(max(point.y - h / 2.0, 0.0), 1.0 - h),
                   w: w, h: h)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Box size").font(.footnote)
                Slider(value: Binding(get: { log(size) },
                                      set: { size = exp($0); if let current = box { setCentre(current.center) } }),
                       in: log(0.003)...log(0.08))
                Toggle(isOn: Binding(get: { zoomed }, set: { on in
                    if on {
                        zoomCentre = box?.center ?? NPoint(x: 0.5, y: 0.5)
                    }
                    zoomed = on
                })) {
                    Label("Zoom", systemImage: "plus.magnifyingglass")
                }
                .toggleStyle(.button)
            }
            HStack(spacing: 10) {
                Button {
                    finish(.noBall)
                } label: {
                    Label("No ball", systemImage: "xmark.circle")
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
                    if let current = box {
                        finish(.ball(current))
                    }
                } label: {
                    Label("Ball is here", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(box == nil)
            }
            Text(hint).font(.caption).foregroundColor(.secondary)
        }
    }

    private var hint: String {
        guard let id = itemID, let item = store.items.first(where: { $0.id == id }) else { return "" }
        if item.guess != nil {
            return String(format: "Red box: your model's guess (%.0f %% sure). Tap or drag to move it. \"Throw away\" if you cannot tell.", item.guessConfidence * 100.0)
        }
        return "Your model found nothing here. Tap where the ball is, or choose \"No ball\"."
    }

    // MARK: Moving on

    private func finish(_ label: TrainingLabel) {
        guard let id = itemID else { return }
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
        zoomed = false
        guard let next = store.pending.first else {
            itemID = nil
            return
        }
        itemID = next.id
        if let guess = next.guess {
            box = guess
            size = max(guess.w, 0.003)
            boxAspect = guess.w > 0 ? guess.h / guess.w : 1.0
        } else {
            size = 0.012
            boxAspect = 16.0 / 9.0 * 0.75     // a slightly wide oval in pixels
        }
        let url = store.imageURL(for: next.id)
        DispatchQueue.global(qos: .userInitiated).async {
            // Full size, so zooming in stays sharp for small, far-away balls.
            let image = TrainingStore.loadImage(at: url, maxPixels: 4096)
            DispatchQueue.main.async {
                if itemID == next.id {
                    if let image = image {
                        picture = image
                    } else {
                        store.discard(next.id)
                        loadNext()
                    }
                }
            }
        }
    }
}
