import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                recordingSection
                trackingSection
                modelSection
                trainingSection
                mountSection
                remoteSection
                streamSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            OrientationLock.allowUpright()
            model.settingsOpened()
        }
        .onDisappear {
            OrientationLock.cameraOnly()
            model.settingsClosed()
        }
    }

    // MARK: - Recording

    private var recordingSection: some View {
        Section {
            Picker("Video quality", selection: $model.settings.quality) {
                ForEach(CaptureQuality.allCases) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            .disabled(model.isRecording)
            Picker("File format", selection: $model.settings.codec) {
                ForEach(RecordingCodec.allCases) { codec in
                    Text(codec.label).tag(codec)
                }
            }
            Toggle("Save recordings to Photos", isOn: $model.settings.saveToPhotos)
            Toggle("Stabilise the picture", isOn: $model.settings.stabilisation)
                .disabled(model.isRecording)
        } header: {
            Text("Recording")
        } footer: {
            Text("\(model.cameraInfo.deviceName)  \(model.freeSpaceText). 4K 60 uses roughly 0.4 GB per minute. With Photos off, recordings stay in the Files app under RugbyCam > Recordings.")
        }
    }

    // MARK: - Tracking

    private var trackingSection: some View {
        Section {
            Toggle("Show what the tracking sees", isOn: $model.settings.showOverlay)
            Toggle("Only use the real lenses (0.5x, 1x, 2x, tele)", isOn: $model.settings.lensStepsOnly)
            Stepper(value: $model.settings.autoZoomMinDisplay, in: 0.5...4.0, step: 0.5) {
                Text("Widest auto zoom: \(SettingsView.number(model.settings.autoZoomMinDisplay))x")
            }
            Stepper(value: $model.settings.autoZoomMaxDisplay, in: 1.0...15.0, step: 0.5) {
                Text("Tightest auto zoom: \(SettingsView.number(model.settings.autoZoomMaxDisplay))x")
            }
            VStack(alignment: .leading) {
                Text("How tightly to frame the players: \(Int(model.settings.zoomTightness * 100.0)) %")
                Slider(value: $model.settings.zoomTightness, in: 0.35...0.80)
            }
            VStack(alignment: .leading) {
                Text("How eagerly the mount follows: \(SettingsView.number(model.settings.followSpeed))")
                Slider(value: $model.settings.followSpeed, in: 0.3...3.0)
            }
            VStack(alignment: .leading) {
                Text("Looks per second: \(Int(model.settings.detectionRate))")
                Slider(value: $model.settings.detectionRate, in: 4.0...30.0, step: 1.0)
            }
            VStack(alignment: .leading) {
                Text("Weakest ball detection to accept: \(SettingsView.number(model.settings.ballConfidence))")
                Slider(value: $model.settings.ballConfidence, in: 0.05...0.60)
            }
            VStack(alignment: .leading) {
                Text("Ball search zoom: \(SettingsView.number(model.settings.searchZoom))x")
                Slider(value: $model.settings.searchZoom, in: 1.0...4.0)
            }
        } header: {
            Text("Tracking")
        } footer: {
            Text("More looks per second and a higher ball search zoom find the ball better but make the phone warmer. If the mount swings back and forth, lower how eagerly it follows.")
        }
    }

    // MARK: - Models

    private var modelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ball model")
                    .font(.subheadline.weight(.semibold))
                Text(model.ballModelStatus)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Player detection")
                    .font(.subheadline.weight(.semibold))
                Text(model.playerModelStatus)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Button("Look for model files again") {
                model.reloadModels()
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Convert your trained best.pt with tools/export_coreml.py, rename the result to BallDetector.mlpackage and copy it into Files > On My iPhone > RugbyCam. Then tap the button above.")
        }
    }

    // MARK: - Training

    private var trainingSection: some View {
        Section {
            NavigationLink {
                TrainingView(store: model.training)
                    .environmentObject(model)
            } label: {
                HStack {
                    Label("Improve the ball model", systemImage: "graduationcap")
                    Spacer()
                    if !model.training.pending.isEmpty {
                        Text("\(model.training.pending.count) to check")
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("Training")
        } footer: {
            Text("Import match videos or keep the moments the ball was lost, mark the ball, and send the pictures to your PC to train the model again.")
        }
    }

    // MARK: - Mount

    private var mountSection: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                Text(model.mountState.label)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if model.mountState == .idle {
                Button("Connect to the XbotGo mount") {
                    model.connectMount()
                }
            } else {
                Button("Disconnect") {
                    model.disconnectMount()
                }
            }
            Button("Forget this mount", role: .destructive) {
                model.forgetMount()
            }
            VStack(alignment: .leading) {
                Text("Arrow button speed: \(Int(model.settings.manualSpeed * 100)) %")
                Slider(value: $model.settings.manualSpeed, in: 0.1...1.0)
            }
            Toggle("Allow tilting up and down", isOn: $model.settings.tiltEnabled)
            Toggle("Reverse left and right", isOn: $model.settings.invertPan)
            Toggle("Reverse up and down", isOn: $model.settings.invertTilt)
            if !model.mountLog.isEmpty {
                ScrollView {
                    Text(model.mountLog.suffix(60).joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 150)
            }
        } header: {
            Text("Mount")
        } footer: {
            Text("Close the XbotGo app first: the mount accepts one connection at a time. With Follow on, the mount turns with the play. The arrows on the camera screen (or on the iPad) turn it by hand and win over the tracking while you hold them. Let go and it stops.")
        }
    }

    // MARK: - iPad remote

    private var remoteSection: some View {
        Section {
            Toggle("Allow control from an iPad", isOn: $model.settings.remoteEnabled)
            if model.settings.remoteEnabled {
                let addresses = model.remoteAddresses
                if addresses.isEmpty {
                    Text("No Wi-Fi or hotspot yet. Connect the iPhone to Wi-Fi, or turn on Personal Hotspot and connect the iPad to it.")
                        .foregroundColor(.orange)
                } else {
                    ForEach(addresses, id: \.self) { address in
                        Text(address)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Text("PIN")
                    Spacer()
                    Text(model.remotePin)
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                }
                Button("Make a new PIN") {
                    model.newRemotePin()
                }
                HStack {
                    Text("iPad")
                    Spacer()
                    Text(model.remoteConnected ? "Connected" : "Not connected")
                        .foregroundColor(model.remoteConnected ? .green : .secondary)
                }
                if let problem = model.remoteProblem {
                    Text(problem).foregroundColor(.orange)
                }
            }
        } header: {
            Text("iPad remote")
        } footer: {
            Text("Put the iPad on the same Wi-Fi as the iPhone. On the pitch, turn on the iPhone's Personal Hotspot and join it with the iPad. Open the RC Remote app on the iPad: it finds this iPhone by itself, then enter the PIN. Without the app, open the address above in Safari. Keep RugbyCam open on the iPhone.")
        }
    }

    // MARK: - Streaming

    private var streamSection: some View {
        Section {
            if !model.streamingAvailable {
                Text("This build has no streaming library. Build the RugbyCam project instead of RugbyCam-Lite to stream.")
                    .foregroundColor(.orange)
            }
            TextField("rtmp://server/app", text: $model.settings.streamURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
            SecureField("Stream key", text: $model.streamKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            Button("Use the YouTube address") {
                model.settings.streamURL = "rtmp://a.rtmp.youtube.com/live2"
            }
            Picker("Stream size", selection: $model.settings.streamResolution) {
                ForEach(StreamResolution.allCases) { resolution in
                    Text(resolution.label).tag(resolution)
                }
            }
            Picker("Stream frames per second", selection: $model.settings.streamFPS) {
                Text("30").tag(30)
                Text("60").tag(60)
            }
            VStack(alignment: .leading) {
                Text("Stream quality: \(SettingsView.number(model.settings.streamBitrateMbps)) Mbit/s")
                Slider(value: $model.settings.streamBitrateMbps, in: 2.0...40.0, step: 0.5)
            }
        } header: {
            Text("Live stream")
        } footer: {
            Text("YouTube: paste the stream key from YouTube Studio > Go live > Stream. Home PC: use rtmp://<PC address>:1935/live as the address and any name (for example pitch) as the key. The stream needs more upload speed than its quality setting: about 12 Mbit/s for 1080p 60 at 9 Mbit/s. Changes apply the next time you go live.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            Text("Hold or mount the phone sideways with the charging port on the right. The app does not turn the picture for other positions.")
            Text("Status: \(model.trackingText)")
                .font(.footnote)
                .foregroundColor(.secondary)
        } header: {
            Text("About")
        }
    }

    private static func number(_ value: Double) -> String {
        return String(format: "%.3g", value)
    }
}
