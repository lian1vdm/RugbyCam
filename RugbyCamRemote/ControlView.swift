import SwiftUI
import UIKit

/// The control panel: live picture, record, follow, zoom, mount arrows, scoreboard.
struct ControlView: View {
    @EnvironmentObject var client: PhoneClient
    @EnvironmentObject var finder: PhoneFinder

    @State private var showSettings = false
    @State private var zoomDraft: Double?
    @State private var confirmReset = false
    @State private var confirmStopRecording = false

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            if wide {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 12) {
                        topBar
                        picture
                        mainButtons
                        notice
                        Spacer(minLength: 0)
                    }
                    ScrollView {
                        VStack(spacing: 14) {
                            zoomPanel
                            mountPanel
                            scorePanel
                            streamPanel
                        }
                    }
                    .frame(width: min(400, geometry.size.width * 0.36))
                }
                .padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        topBar
                        picture
                        mainButtons
                        notice
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 14) {
                                zoomPanel
                                mountPanel
                            }
                            VStack(spacing: 14) {
                                scorePanel
                                streamPanel
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            RemoteSettingsView()
                .environmentObject(client)
        }
        .confirmationDialog("Reset the scoreboard?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to 0 : 0 and 1st half", role: .destructive) {
                client.command("scoreReset")
            }
        }
        .confirmationDialog("Stop recording?", isPresented: $confirmStopRecording, titleVisibility: .visible) {
            Button("Stop recording", role: .destructive) {
                client.command("record")
            }
        }
        .onChange(of: finder.phones) { _, phones in
            // The iPhone got a new address (for example after switching to the hotspot): follow it.
            guard client.link == .unreachable else { return }
            let addresses = phones.compactMap { $0.address }
            if addresses.count == 1, addresses[0] != client.address {
                client.connect(to: addresses[0], pin: client.pin)
            }
        }
    }

    private var status: PhoneStatus? {
        return client.status
    }

    private var clockText: String {
        let time = client.status?.recordingTime ?? ""
        return time.isEmpty ? "0:00" : time
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            linkChip
            if let battery = status?.battery, battery >= 0 {
                chip(systemImage: batteryIcon(battery, charging: status?.charging ?? false),
                     text: "\(battery) %",
                     color: battery <= 15 && !(status?.charging ?? false) ? Theme.red : .white)
            }
            if status?.hot == true {
                chip(systemImage: "thermometer.sun.fill", text: "Hot", color: Theme.red)
            }
            if let free = status?.freeSpace, !free.isEmpty {
                chip(systemImage: "internaldrive", text: free, color: .white)
            }
            if let mount = status?.mount, !mount.isEmpty {
                chip(systemImage: status?.mountReady == true ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
                     text: status?.mountReady == true ? "Mount ready" : mount,
                     color: status?.mountReady == true ? Theme.green : Theme.dim)
            }
            Spacer(minLength: 0)
            Button {
                client.loadSettings()
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            Menu {
                Button("Connect to another iPhone") {
                    client.disconnect()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
        }
        .lineLimit(1)
    }

    private var linkChip: some View {
        let (text, color): (String, Color) = {
            switch client.link {
            case .connected: return ("Connected", Theme.green)
            case .connecting: return ("Connecting…", Theme.gold)
            case .unreachable: return ("iPhone not answering", Theme.red)
            default: return ("Not connected", Theme.dim)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }

    private func chip(systemImage: String, text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.subheadline)
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }

    private func batteryIcon(_ level: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    // MARK: - Picture

    private var picture: some View {
        let image = client.picture
        let aspect = image.map { $0.size.width / max($0.size.height, 1) } ?? (16.0 / 9.0)
        let current = status
        return ZStack {
            Color(white: 0.07)
            if let image = image {
                Image(uiImage: image)
                    .resizable()
            }
            Canvas { context, size in
                guard let current = current else { return }
                for box in current.players ?? [] where box.count == 4 {
                    let rect = CGRect(x: box[0] * size.width, y: box[1] * size.height,
                                      width: box[2] * size.width, height: box[3] * size.height)
                    context.stroke(Path(rect), with: .color(.white.opacity(0.55)), lineWidth: 1.5)
                }
                if let ball = current.ball, ball.count == 4 {
                    let rect = CGRect(x: ball[0] * size.width, y: ball[1] * size.height,
                                      width: ball[2] * size.width, height: ball[3] * size.height)
                        .insetBy(dx: -4, dy: -4)
                    let color = current.ballConfirmed == true ? Theme.green : Theme.gold
                    context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(color), lineWidth: 3)
                }
            }
            VStack {
                HStack {
                    if current?.recording == true {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.red).frame(width: 12, height: 12)
                            Text(current?.recordingTime ?? "")
                                .font(.headline.monospacedDigit())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                    }
                    Spacer()
                    if let zoom = current?.zoomText, !zoom.isEmpty {
                        Text(zoom)
                            .font(.headline.monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Capsule())
                    }
                }
                Spacer()
                if let tracking = current?.tracking, !tracking.isEmpty {
                    Text(tracking)
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            if current?.cameraPaused == true {
                overlayMessage("The settings are open on the iPhone, so the camera is paused.")
            } else if client.link == .connecting {
                overlayMessage("Connecting to the iPhone…", spinner: true)
            } else if client.link == .unreachable {
                VStack(spacing: 12) {
                    overlayMessage("The iPhone is not answering. Is RugbyCam open on it and on the same Wi-Fi or hotspot?", spinner: true)
                    Button("Choose the iPhone again") {
                        client.disconnect()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if image == nil {
                overlayMessage("Waiting for the picture…", spinner: true)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity)
    }

    private func overlayMessage(_ text: String, spinner: Bool = false) -> some View {
        HStack(spacing: 10) {
            if spinner {
                ProgressView()
            }
            Text(text)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .background(Color.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(20)
    }

    // MARK: - Record, follow, auto zoom

    private var mainButtons: some View {
        HStack(spacing: 12) {
            Button {
                if status?.recording == true {
                    confirmStopRecording = true
                } else {
                    client.command("record")
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: status?.recording == true ? "stop.fill" : "record.circle")
                        .font(.title2)
                    Text(status?.recording == true ? "Stop  \(status?.recordingTime ?? "")" : "Record")
                        .font(.title3.weight(.bold).monospacedDigit())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.red.opacity(status?.recording == true ? 1.0 : 0.85))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            toggleButton("Follow", systemImage: "scope", isOn: status?.follow) {
                client.toggle("follow", isOn: status?.follow)
            }
            toggleButton("Auto zoom", systemImage: "plus.magnifyingglass", isOn: status?.autoZoom) {
                client.toggle("autozoom", isOn: status?.autoZoom)
            }
        }
        .disabled(client.link != .connected)
    }

    private func toggleButton(_ title: String, systemImage: String, isOn: Bool?, action: @escaping () -> Void) -> some View {
        let on = isOn ?? false
        return Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title2)
                Text(title + (on ? " on" : " off"))
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(on ? Theme.gold : Color.white.opacity(0.1))
            .foregroundColor(on ? .black : .white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let text = status?.notice, !text.isEmpty {
            Text(text)
                .foregroundColor(Theme.gold)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Zoom

    private var zoomPanel: some View {
        panel("Zoom") {
            HStack(spacing: 10) {
                smallButton(systemImage: "minus.magnifyingglass") {
                    client.command("zoomstep", 0.8)
                }
                Slider(value: Binding(get: {
                    zoomDraft ?? status?.zoomPosition ?? 0
                }, set: { value in
                    zoomDraft = value
                    client.zoom(to: value, final: false)
                }), in: 0...1, onEditingChanged: { editing in
                    if !editing, let value = zoomDraft {
                        client.zoom(to: value, final: true)
                        // Keep showing the dragged position until the iPhone has caught up.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            zoomDraft = nil
                        }
                    }
                })
                smallButton(systemImage: "plus.magnifyingglass") {
                    client.command("zoomstep", 1.25)
                }
            }
            if status?.autoZoom == true {
                Text("Auto zoom is on: it takes over again after you zoom by hand.")
                    .font(.caption)
                    .foregroundColor(Theme.dim)
            }
        }
        .disabled(client.link != .connected)
    }

    private func smallButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 48, height: 44)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .foregroundColor(.white)
    }

    // MARK: - Mount arrows

    private var mountPanel: some View {
        panel("Turn the mount") {
            let size: CGFloat = 76
            VStack(spacing: 8) {
                HoldButton(systemImage: "chevron.up",
                           onPress: { client.startMove("tilt", -1) },
                           onRelease: { client.stopMove() })
                    .frame(width: size, height: size)
                HStack(spacing: 8) {
                    HoldButton(systemImage: "chevron.left",
                               onPress: { client.startMove("pan", -1) },
                               onRelease: { client.stopMove() })
                        .frame(width: size, height: size)
                    VStack {
                        Text(client.moving ? "Moving" : "Hold")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(client.moving ? Theme.gold : Theme.dim)
                    }
                    .frame(width: size, height: size)
                    HoldButton(systemImage: "chevron.right",
                               onPress: { client.startMove("pan", 1) },
                               onRelease: { client.stopMove() })
                        .frame(width: size, height: size)
                }
                HoldButton(systemImage: "chevron.down",
                           onPress: { client.startMove("tilt", 1) },
                           onRelease: { client.stopMove() })
                    .frame(width: size, height: size)
            }
            .frame(maxWidth: .infinity)
            if status?.mountReady != true {
                Text("The mount is not linked to the iPhone yet. Connect it in Settings > Mount.")
                    .font(.caption)
                    .foregroundColor(Theme.dim)
            } else {
                Text("The arrows win over Follow while you hold them. Speed: Settings > Mount.")
                    .font(.caption)
                    .foregroundColor(Theme.dim)
            }
        }
        .disabled(client.link != .connected)
    }

    // MARK: - Scoreboard

    private var scorePanel: some View {
        panel("Scoreboard") {
            HStack(alignment: .top, spacing: 12) {
                teamColumn(home: true)
                VStack(spacing: 4) {
                    Text(clockText)
                        .font(.title3.weight(.bold).monospacedDigit())
                    Text(status?.period == 2 ? "2nd half" : "1st half")
                        .font(.caption)
                        .foregroundColor(Theme.dim)
                }
                .frame(width: 70)
                .padding(.top, 34)
                teamColumn(home: false)
            }
            Text("The game clock runs from when recording starts.")
                .font(.caption)
                .foregroundColor(Theme.dim)
            HStack(spacing: 8) {
                Button(status?.period == 2 ? "Back to 1st half" : "Change to 2nd half") {
                    client.command("period", status?.period == 2 ? 1 : 2)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Reset") {
                    confirmReset = true
                }
                .buttonStyle(.bordered)
                .tint(Theme.red)
            }
            Toggle("Show the scoreboard in the video", isOn: Binding(get: {
                status?.scoreInVideo ?? false
            }, set: { value in
                client.command("scoreShow", value ? 1 : 0)
            }))
        }
        .disabled(client.link != .connected)
    }

    private func teamColumn(home: Bool) -> some View {
        let name = (home ? status?.home : status?.away) ?? ""
        let score = (home ? status?.homeScore : status?.awayScore) ?? 0
        let command = home ? "scoreHome" : "scoreAway"
        let color = home ? Theme.gold : Theme.green
        return VStack(spacing: 8) {
            TeamNameField(serverName: name, placeholder: home ? "Home" : "Away") { newName in
                client.setSetting(home ? "homeName" : "awayName", newName)
            }
            Text("\(score)")
                .font(.system(size: 46, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundColor(color)
            HStack(spacing: 6) {
                pointsButton("Try +5") { client.command(command, 5) }
                pointsButton("Conv +2") { client.command(command, 2) }
            }
            HStack(spacing: 6) {
                pointsButton("Pen +3") { client.command(command, 3) }
                pointsButton("−1") { client.command(command, -1) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func pointsButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .foregroundColor(.white)
    }

    // MARK: - Live stream

    private var streamPanel: some View {
        panel("Live stream") {
            if status?.streamAvailable == false {
                Text("This iPhone build has no streaming.")
                    .font(.callout)
                    .foregroundColor(Theme.dim)
            } else {
                Button {
                    client.command("stream")
                } label: {
                    Label(status?.streamOn == true ? "Stop the stream" : "Go live",
                          systemImage: status?.streamOn == true ? "stop.circle.fill" : "dot.radiowaves.up.forward")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(status?.streamOn == true ? Theme.red : Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .foregroundColor(.white)
                if let text = status?.streamText, !text.isEmpty {
                    Text(text)
                        .font(.caption)
                        .foregroundColor(Theme.dim)
                }
            }
        }
        .disabled(client.link != .connected)
    }

    // MARK: - Helpers

    private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.dim)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// A team name box that shows the iPhone's name until you start typing.
struct TeamNameField: View {
    let serverName: String
    let placeholder: String
    let onCommit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .multilineTextAlignment(.center)
            .font(.headline)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled(true)
            .focused($focused)
            .submitLabel(.done)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear { text = serverName }
            .onChange(of: serverName) { _, value in
                if !focused { text = value }
            }
            .onChange(of: text) { _, value in
                if value.count > 16 { text = String(value.prefix(16)) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused && text != serverName {
                    onCommit(text)
                }
            }
            .onSubmit {
                focused = false
            }
    }
}

/// An arrow that reports press and release straight from UIKit, so letting go is never missed,
/// also inside a scroll view (a scroll that takes over the touch counts as letting go).
struct HoldButton: UIViewRepresentable {
    let systemImage: String
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        let configuration = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)
        button.setImage(UIImage(systemName: systemImage, withConfiguration: configuration), for: .normal)
        button.tintColor = .white
        button.backgroundColor = Coordinator.idleColor
        button.layer.cornerRadius = 16
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed(_:)), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.released(_:)),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.parent = self
        uiView.alpha = context.environment.isEnabled ? 1.0 : 0.4
        uiView.isEnabled = context.environment.isEnabled
    }

    final class Coordinator: NSObject {
        static let idleColor = UIColor(white: 1.0, alpha: 0.14)
        static let heldColor = UIColor(red: 0.96, green: 0.71, blue: 0.13, alpha: 0.9)

        var parent: HoldButton
        private var held = false

        init(_ parent: HoldButton) {
            self.parent = parent
        }

        @objc func pressed(_ sender: UIButton) {
            held = true
            sender.backgroundColor = Coordinator.heldColor
            sender.tintColor = .black
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            parent.onPress()
        }

        @objc func released(_ sender: UIButton) {
            sender.backgroundColor = Coordinator.idleColor
            sender.tintColor = .white
            guard held else { return }
            held = false
            parent.onRelease()
        }
    }
}
