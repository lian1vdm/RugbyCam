import SwiftUI

// MARK: - Arrow pad for the mount

/// Four arrows. Holding one turns the mount; letting go stops it.
struct MountPad: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let size: CGFloat = 44
        VStack(spacing: 4) {
            HoldArrow(systemImage: "chevron.up", size: size) { model.manualMove(pan: 0, tilt: -1) }
            HStack(spacing: 4) {
                HoldArrow(systemImage: "chevron.left", size: size) { model.manualMove(pan: -1, tilt: 0) }
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(model.mountState.canMove ? .green : .white.opacity(0.5))
                    .frame(width: size, height: size)
                HoldArrow(systemImage: "chevron.right", size: size) { model.manualMove(pan: 1, tilt: 0) }
            }
            HoldArrow(systemImage: "chevron.down", size: size) { model.manualMove(pan: 0, tilt: 1) }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.45)))
        .opacity(model.mountState.canMove ? 1.0 : 0.45)
    }
}

/// A button that repeats its action while it is held and stops the mount on release.
struct HoldArrow: View {
    @EnvironmentObject var model: AppModel
    let systemImage: String
    let size: CGFloat
    let action: () -> Void
    @State private var timer: Timer?

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .bold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(timer == nil ? 0.15 : 0.4)))
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard timer == nil else { return }
                        action()
                        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                            action()
                        }
                    }
                    .onEnded { _ in
                        timer?.invalidate()
                        timer = nil
                        model.manualStop()
                    }
            )
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }
}

// MARK: - Scoreboard on the camera screen

/// The score at the top of the camera screen. Tap it to change the score.
struct ScoreChip: View {
    @EnvironmentObject var model: AppModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(model.score.home).lineLimit(1)
                Text("\(model.score.homeScore) – \(model.score.awayScore)")
                    .monospacedDigit()
                    .foregroundColor(.yellow)
                Text(model.score.away).lineLimit(1)
                Text(model.recordingTimeText)
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.8))
                if model.score.showInVideo {
                    Image(systemName: "film")
                        .foregroundColor(.green)
                }
            }
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.6)))
        }
    }
}

/// Change the score, the team names and the half.
struct ScoreboardEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show the scoreboard in the video", isOn: $model.score.showInVideo)
                    HStack {
                        Text("Game time")
                        Spacer()
                        Text(model.recordingTimeText)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Picker("Half", selection: $model.score.period) {
                        Text("1st half").tag(1)
                        Text("2nd half").tag(2)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("The game time starts when you start recording. With the scoreboard in the video, it is part of the recording and the live stream.")
                }
                teamSection(home: true)
                teamSection(home: false)
                Section {
                    Button("Set both scores to 0", role: .destructive) {
                        model.resetScore()
                    }
                }
            }
            .navigationTitle("Scoreboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func teamSection(home: Bool) -> some View {
        Section {
            TextField("Team name", text: home ? $model.score.home : $model.score.away)
            HStack {
                Text(home ? "\(model.score.homeScore)" : "\(model.score.awayScore)")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 60, alignment: .leading)
                Spacer()
                pointsButton("Try +5", 5, home)
                pointsButton("Conv. +2", 2, home)
                pointsButton("Pen. +3", 3, home)
                pointsButton("−1", -1, home)
            }
        } header: {
            Text(home ? "Home team" : "Away team")
        }
    }

    private func pointsButton(_ title: String, _ points: Int, _ home: Bool) -> some View {
        Button(title) {
            model.addPoints(home: home, points)
        }
        .buttonStyle(.bordered)
        .font(.footnote.weight(.semibold))
    }
}

/// Draw on the live picture how you would frame it right now. The camera zooms
/// to it and the auto zoom learns from it.
struct LiveFrameDrawer: View {
    @EnvironmentObject var model: AppModel
    @Binding var active: Bool

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let video = VideoLayout.videoRect(in: geometry.size)
            ZStack {
                Color.black.opacity(0.15)
                Canvas { context, _ in
                    if let suggestion = model.snapshot.frame {
                        context.stroke(Path(LiveFrameDrawer.place(suggestion, in: video)), with: .color(.yellow),
                                       style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    }
                    if let box = drawnBox(in: video) {
                        context.stroke(Path(LiveFrameDrawer.place(box, in: video)), with: .color(.green), lineWidth: 3)
                    }
                }
                VStack {
                    Spacer()
                    Text("Draw the frame you would film now (\(model.snapshot.situation.label.lowercased())). Yellow: what the app picks.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .padding(.bottom, 70)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        start = value.startLocation
                        current = value.location
                    }
                    .onEnded { _ in
                        if let box = drawnBox(in: video), box.w >= 0.04 {
                            model.userFrame(box)
                        }
                        start = nil
                        current = nil
                        active = false
                    }
            )
        }
    }

    /// The drawn box in picture coordinates, kept in the shape of the picture.
    private func drawnBox(in video: CGRect) -> NBox? {
        guard let a = start, let b = current, video.width > 0, video.height > 0 else { return nil }
        let ax = Double((a.x - video.minX) / video.width)
        let ay = Double((a.y - video.minY) / video.height)
        let dx = Double((b.x - a.x) / video.width)
        let dy = Double((b.y - a.y) / video.height)
        let size = Geo.clamp(max(abs(dx), abs(dy)), 0.0, 1.0)
        let x = dx < 0 ? ax - size : ax
        let y = dy < 0 ? ay - size : ay
        return NBox(x: Geo.clamp(x, 0, 1 - size), y: Geo.clamp(y, 0, 1 - size), w: size, h: size)
    }

    private static func place(_ box: NBox, in video: CGRect) -> CGRect {
        return CGRect(x: video.minX + CGFloat(box.x) * video.width, y: video.minY + CGFloat(box.y) * video.height,
                      width: CGFloat(box.w) * video.width, height: CGFloat(box.h) * video.height)
    }
}
