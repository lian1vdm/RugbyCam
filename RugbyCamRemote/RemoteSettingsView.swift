import SwiftUI

/// One setting on the iPhone that the iPad may change. The keys and limits match
/// what RugbyCam on the iPhone accepts (and the web control panel).
struct SettingField: Identifiable {
    enum Kind {
        case toggle
        case choice([(value: String, label: String)])
        case slider(min: Double, max: Double, step: Double, format: (Double) -> String)
        case text
        case mount
        case model
        case note
    }

    let id: String
    let title: String
    let kind: Kind
    var lockedWhileRecording = false

    init(_ key: String, _ title: String, _ kind: Kind, lockedWhileRecording: Bool = false) {
        self.id = key
        self.title = title
        self.kind = kind
        self.lockedWhileRecording = lockedWhileRecording
    }

    static func percent(_ value: Double) -> String { return "\(Int((value * 100).rounded())) %" }
    static func times(_ value: Double) -> String { return String(format: "%gx", value) }
    static func twoPlaces(_ value: Double) -> String { return String(format: "%.2f", value) }
    static func whole(_ value: Double) -> String { return "\(Int(value.rounded()))" }

    static let sections: [(String, [SettingField])] = [
        ("Recording", [
            SettingField("quality", "Video quality",
                         .choice([("uhd60", "4K 60"), ("uhd30", "4K 30"), ("hd60", "1080p 60")]),
                         lockedWhileRecording: true),
            SettingField("codec", "File format",
                         .choice([("hevc", "HEVC (smaller files)"), ("h264", "H.264 (most compatible)")])),
            SettingField("saveToPhotos", "Save recordings to Photos", .toggle),
            SettingField("stabilisation", "Stabilise the picture", .toggle, lockedWhileRecording: true),
        ]),
        ("Tracking", [
            SettingField("showOverlay", "Show what the tracking sees", .toggle),
            SettingField("lensStepsOnly", "Only use the real lenses (0.5x, 1x, 2x, tele)", .toggle),
            SettingField("autoZoomMinDisplay", "Widest auto zoom", .slider(min: 0.5, max: 4, step: 0.5, format: SettingField.times)),
            SettingField("autoZoomMaxDisplay", "Tightest auto zoom", .slider(min: 1, max: 15, step: 0.5, format: SettingField.times)),
            SettingField("zoomTightness", "How tightly to frame the players", .slider(min: 0.35, max: 0.8, step: 0.01, format: SettingField.percent)),
            SettingField("followSpeed", "How eagerly the mount follows", .slider(min: 0.3, max: 3, step: 0.05, format: SettingField.twoPlaces)),
            SettingField("detectionRate", "Looks per second", .slider(min: 4, max: 30, step: 1, format: SettingField.whole)),
            SettingField("ballConfidence", "Weakest ball detection to accept", .slider(min: 0.05, max: 0.6, step: 0.01, format: SettingField.twoPlaces)),
            SettingField("searchZoom", "Ball search zoom", .slider(min: 1, max: 4, step: 0.1, format: { String(format: "%.1fx", $0) })),
        ]),
        ("Mount", [
            SettingField("_mount", "Status", .mount),
            SettingField("tiltEnabled", "Allow tilting up and down", .toggle),
            SettingField("invertPan", "Reverse left and right", .toggle),
            SettingField("invertTilt", "Reverse up and down", .toggle),
            SettingField("manualSpeed", "Arrow button speed", .slider(min: 0.1, max: 1, step: 0.05, format: SettingField.percent)),
        ]),
        ("Training", [
            SettingField("saveHardFrames", "While recording, save moments the ball is lost", .toggle),
            SettingField("importKeep", "Pictures to keep per imported video", .slider(min: 20, max: 200, step: 10, format: SettingField.whole)),
            SettingField("_ballModel", "Ball model", .model),
        ]),
        ("Live stream", [
            SettingField("streamURL", "Stream address", .text),
            SettingField("streamResolution", "Stream size",
                         .choice([("p720", "720p"), ("p1080", "1080p"), ("p1440", "1440p"), ("p2160", "4K")])),
            SettingField("streamFPS", "Stream frames per second", .choice([("30", "30"), ("60", "60")])),
            SettingField("streamBitrateMbps", "Stream quality", .slider(min: 2, max: 40, step: 0.5, format: { String(format: "%.1f Mbit/s", $0) })),
            SettingField("_streamNote", "The stream key can only be entered on the iPhone. Stream changes apply the next time you go live.", .note),
        ]),
    ]
}

struct RemoteSettingsView: View {
    @EnvironmentObject var client: PhoneClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if client.settings.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading the iPhone's settings…")
                        }
                    }
                }
                if let problem = client.settingsProblem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(Theme.gold)
                    }
                }
                if !client.settings.isEmpty {
                    ForEach(0..<SettingField.sections.count, id: \.self) { index in
                        Section(SettingField.sections[index].0) {
                            ForEach(SettingField.sections[index].1) { field in
                                row(field)
                            }
                        }
                    }
                }
            }
            .navigationTitle(deviceTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        client.loadSettings()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .onAppear {
            client.loadSettings()
        }
    }

    private var deviceTitle: String {
        let device = client.text("_device")
        return device.isEmpty ? "iPhone settings" : "Settings on \(device)"
    }

    private var recording: Bool {
        return client.bool("_recording")
    }

    @ViewBuilder
    private func row(_ field: SettingField) -> some View {
        let locked = field.lockedWhileRecording && recording
        let title = field.title + (locked ? " (stop recording first)" : "")
        switch field.kind {
        case .toggle:
            Toggle(title, isOn: Binding(get: {
                client.bool(field.id)
            }, set: { value in
                client.setSetting(field.id, value ? "1" : "0")
            }))
            .disabled(locked)
        case .choice(let options):
            Picker(title, selection: Binding(get: {
                choiceValue(field.id)
            }, set: { value in
                client.setSetting(field.id, value)
            })) {
                ForEach(0..<options.count, id: \.self) { index in
                    Text(options[index].label).tag(options[index].value)
                }
            }
            .disabled(locked)
        case .slider(let min, let max, let step, let format):
            SliderRow(title: title, serverValue: client.number(field.id), range: min...max, step: step, format: format) { value in
                client.setSetting(field.id, String(value))
            }
            .disabled(locked)
        case .text:
            TextRow(title: title, serverValue: client.text(field.id)) { value in
                client.setSetting(field.id, value)
            }
        case .mount:
            HStack {
                Text("Status")
                Spacer()
                Text(client.text("_mount"))
                    .foregroundColor(Theme.dim)
                    .multilineTextAlignment(.trailing)
            }
            Button(client.bool("_mountIdle") ? "Connect to the XbotGo mount" : "Disconnect the mount") {
                client.command(client.bool("_mountIdle") ? "mountConnect" : "mountDisconnect")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    client.loadSettings()
                }
            }
        case .model:
            VStack(alignment: .leading, spacing: 4) {
                Text("Ball model")
                Text(client.text("_ballModel"))
                    .font(.footnote)
                    .foregroundColor(Theme.dim)
            }
            Button("Look for model files again") {
                client.command("reloadModels")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    client.loadSettings()
                }
            }
        case .note:
            Text(field.title)
                .font(.footnote)
                .foregroundColor(Theme.dim)
        }
    }

    /// Pickers need the exact option text, also for numbers such as the 30 or 60 frames.
    private func choiceValue(_ key: String) -> String {
        let text = client.text(key)
        if let number = Double(text), number == number.rounded() {
            return String(Int(number))
        }
        return text
    }
}

/// A slider that only sends its value when you let go.
struct SliderRow: View {
    let title: String
    let serverValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let onCommit: (Double) -> Void

    @State private var value = 0.0
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .foregroundColor(Theme.dim)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step, onEditingChanged: { isEditing in
                editing = isEditing
                if !isEditing {
                    onCommit(value)
                }
            })
        }
        .onAppear {
            value = clamp(serverValue)
        }
        .onChange(of: serverValue) { _, newValue in
            if !editing {
                value = clamp(newValue)
            }
        }
    }

    private func clamp(_ input: Double) -> Double {
        return min(max(input, range.lowerBound), range.upperBound)
    }
}

/// A text box that sends its text when you press return or leave it.
struct TextRow: View {
    let title: String
    let serverValue: String
    let onCommit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextField(title, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .focused($focused)
                .onSubmit {
                    focused = false
                }
        }
        .onAppear {
            text = serverValue
        }
        .onChange(of: serverValue) { _, newValue in
            if !focused {
                text = newValue
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && text != serverValue {
                onCommit(text)
            }
        }
    }
}
