// Copy of RugbyCam/UI/FrameEditor.swift (the iPad app is a separate app).
import SwiftUI
import UIKit

/// Shows a picture and lets the person draw the frame they would have filmed:
/// drag to draw (it keeps the shape of the picture), drag inside it to move it,
/// pinch to make it bigger or smaller, tap to move it there.
struct FrameEditor: View {
    let image: UIImage
    var players: [NBox] = []
    var ball: NBox?
    var appFrame: NBox?
    @Binding var frame: NBox?

    private enum Mode {
        case create(start: NPoint)
        case move(original: NBox, start: NPoint)
    }

    @State private var mode: Mode?
    @State private var pinchBase: NBox?

    var body: some View {
        GeometryReader { geometry in
            let area = FrameEditor.fit(image.size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .frame(width: area.width, height: area.height)
                    .position(x: area.midX, y: area.midY)
                Canvas { context, _ in
                    for player in players {
                        context.stroke(Path(FrameEditor.place(player, in: area)),
                                       with: .color(.white.opacity(0.45)), lineWidth: 1)
                    }
                    if let ball = ball {
                        let rect = FrameEditor.place(ball, in: area).insetBy(dx: -5, dy: -5)
                        context.stroke(Path(ellipseIn: rect), with: .color(.red), lineWidth: 2)
                    }
                    if let suggestion = appFrame {
                        context.stroke(Path(FrameEditor.place(suggestion, in: area)),
                                       with: .color(.yellow),
                                       style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    }
                    if let chosen = frame {
                        let rect = FrameEditor.place(chosen, in: area)
                        // Darken what would be outside the picture.
                        var outside = Path(area)
                        outside.addRect(rect)
                        context.fill(outside, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
                        context.stroke(Path(rect), with: .color(.green), lineWidth: 3)
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragChanged(value, area: area) }
                    .onEnded { value in dragEnded(value, area: area) }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        mode = nil
                        guard let base = pinchBase ?? frame ?? appFrame else { return }
                        if pinchBase == nil {
                            pinchBase = base
                        }
                        let size = Geo.clamp(base.w / Double(value.magnification), 0.05, 1.0)
                        frame = FrameEditor.square(centre: base.center, size: size)
                    }
                    .onEnded { _ in
                        pinchBase = nil
                    }
            )
        }
    }

    // MARK: - Touches

    private func dragChanged(_ value: DragGesture.Value, area: CGRect) {
        guard pinchBase == nil else { return }
        let start = FrameEditor.normalised(value.startLocation, in: area)
        let point = FrameEditor.normalised(value.location, in: area)
        if mode == nil {
            if let current = frame, current.contains(start) {
                mode = .move(original: current, start: start)
            } else {
                mode = .create(start: start)
            }
        }
        switch mode {
        case .create(let anchor)?:
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            let size = min(max(abs(dx), abs(dy)), 1.0)
            guard size >= 0.03 else { return }
            let x = dx < 0 ? anchor.x - size : anchor.x
            let y = dy < 0 ? anchor.y - size : anchor.y
            frame = FrameEditor.inside(NBox(x: x, y: y, w: size, h: size))
        case .move(let original, let anchor)?:
            let moved = NBox(x: original.x + point.x - anchor.x, y: original.y + point.y - anchor.y,
                             w: original.w, h: original.h)
            frame = FrameEditor.inside(moved)
        case nil:
            break
        }
    }

    private func dragEnded(_ value: DragGesture.Value, area: CGRect) {
        defer { mode = nil }
        let start = FrameEditor.normalised(value.startLocation, in: area)
        let point = FrameEditor.normalised(value.location, in: area)
        let moved = max(abs(point.x - start.x), abs(point.y - start.y))
        if case .create? = mode, moved < 0.03 {
            // A tap: put the frame (or the app's suggestion) there.
            let size = frame?.w ?? appFrame?.w ?? 0.5
            frame = FrameEditor.square(centre: start, size: size)
        }
    }

    // MARK: - Maths

    static func fit(_ imageSize: CGSize, in size: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    static func place(_ box: NBox, in area: CGRect) -> CGRect {
        return CGRect(x: area.minX + CGFloat(box.x) * area.width, y: area.minY + CGFloat(box.y) * area.height,
                      width: CGFloat(box.w) * area.width, height: CGFloat(box.h) * area.height)
    }

    static func normalised(_ point: CGPoint, in area: CGRect) -> NPoint {
        return NPoint(x: Geo.clamp(Double((point.x - area.minX) / max(area.width, 1)), 0, 1),
                      y: Geo.clamp(Double((point.y - area.minY) / max(area.height, 1)), 0, 1))
    }

    static func square(centre: NPoint, size: Double) -> NBox {
        return inside(NBox(x: centre.x - size / 2, y: centre.y - size / 2, w: size, h: size))
    }

    /// Keeps a frame inside the picture.
    static func inside(_ box: NBox) -> NBox {
        let size = Geo.clamp(box.w, 0.03, 1.0)
        return NBox(x: Geo.clamp(box.x, 0, 1 - size), y: Geo.clamp(box.y, 0, 1 - size), w: size, h: size)
    }
}

/// The row of situation buttons for the framing question.
struct SituationPicker: View {
    @Binding var situation: PlaySituation

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(PlaySituation.choosable) { choice in
                    Button {
                        situation = choice
                    } label: {
                        Text(choice.label)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(choice == situation ? Color.yellow : Color.white.opacity(0.12)))
                            .foregroundColor(choice == situation ? .black : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
