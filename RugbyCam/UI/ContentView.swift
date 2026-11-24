import SwiftUI

/// The main screen: the live picture with the controls on top of it.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            CameraPreview(session: model.camera.session)
                .ignoresSafeArea()
            if model.settings.showOverlay {
                TrackingOverlay(snapshot: model.snapshot)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            VStack(spacing: 8) {
                topBar
                Spacer(minLength: 0)
                if let notice = model.notice {
                    noticeBanner(notice)
                }
                bottomBar
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            HStack {
                Spacer(minLength: 0)
                sideButtons
            }
            .padding(.trailing, 14)
            if let problem = model.cameraProblem {
                problemCard(problem)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
        }
        .onAppear {
            model.start()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            if model.isRecording {
                Chip(text: model.recordingTimeText, systemImage: "record.circle.fill", tint: .red)
            }
            Chip(text: cameraText, systemImage: "video.fill", tint: .white)
            Chip(text: model.trackingText, systemImage: "scope", tint: trackingTint)
            Chip(text: model.mountState.label,
                 systemImage: "dot.radiowaves.left.and.right",
                 tint: model.mountState.canMove ? .green : .white)
            if model.streamState != .off {
                Chip(text: model.streamState.label,
                     systemImage: "antenna.radiowaves.left.and.right",
                     tint: model.streamState == .live ? .red : .yellow)
            }
            if model.isHot {
                Chip(text: "Phone is hot", systemImage: "thermometer.high", tint: .orange)
            }
            if model.remoteConnected {
                Chip(text: "iPad", systemImage: "ipad.landscape", tint: .green)
            }
            Spacer(minLength: 0)
        }
    }

    private var cameraText: String {
        let info = model.cameraInfo
        guard info.width > 0 else {
            return "Starting the camera"
        }
        var text = "\(info.width)x\(info.height) · \(model.captureFPS) fps"
        if model.droppedFrames > 0 {
            text += " · \(model.droppedFrames) dropped"
        }
        return text
    }

    private var trackingTint: Color {
        switch model.snapshot.state {
        case .ball: return .green
        case .ballHeld: return .yellow
        case .players: return .cyan
        case .searching: return .white
        }
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        HStack(spacing: 10) {
            ForEach(model.cameraInfo.lensStops) { stop in
                Button(stop.label) {
                    model.userZoom(to: stop.factor, glide: true)
                }
                .buttonStyle(LensButtonStyle(active: abs(model.zoom - stop.factor) < 0.03 * stop.factor))
            }
            Slider(value: zoomSlider, in: 0.0...1.0)
                .frame(maxWidth: 220)
                .tint(.yellow)
            Text(model.zoomText)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white)
                .frame(width: 52, alignment: .leading)
            Spacer(minLength: 0)
            Toggle(isOn: followSwitch) {
                Label("Follow", systemImage: "arrow.left.and.right")
            }
            .toggleStyle(.button)
            .tint(.green)
            Toggle(isOn: autoZoomSwitch) {
                Label("Auto zoom", systemImage: "plus.magnifyingglass")
            }
            .toggleStyle(.button)
            .tint(.green)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
        }
        .padding(.trailing, 90)
    }

    private var zoomSlider: Binding<Double> {
        return Binding(get: { model.zoomSliderPosition },
                       set: { model.setZoomSliderPosition($0) })
    }

    private var followSwitch: Binding<Bool> {
        return Binding(get: { model.followEnabled },
                       set: { model.setFollow($0) })
    }

    private var autoZoomSwitch: Binding<Bool> {
        return Binding(get: { model.autoZoomEnabled },
                       set: { model.setAutoZoom($0) })
    }

    // MARK: - Side

    private var sideButtons: some View {
        VStack(spacing: 18) {
            Button {
                model.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 66, height: 66)
                    if model.isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red)
                            .frame(width: 28, height: 28)
                    } else {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 54, height: 54)
                    }
                }
            }
            Button {
                model.toggleStream()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 20, weight: .semibold))
                    Text(model.streamState == .off ? "Go live" : "Stop")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(model.streamState == .live ? .red : .white)
                .frame(width: 66, height: 50)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.5)))
            }
        }
    }

    // MARK: - Messages

    private func noticeBanner(_ text: String) -> some View {
        return Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.75)))
            .padding(.trailing, 90)
    }

    private func problemCard(_ text: String) -> some View {
        return Text(text)
            .font(.headline)
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.85)))
            .padding(40)
    }
}

/// A small rounded label used in the status row.
struct Chip: View {
    let text: String
    let systemImage: String
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundColor(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

/// The round lens buttons (0.5, 1, 2, 4).
struct LensButtonStyle: ButtonStyle {
    var active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundColor(active ? .yellow : .white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Color.black.opacity(configuration.isPressed ? 0.8 : 0.5)))
    }
}
