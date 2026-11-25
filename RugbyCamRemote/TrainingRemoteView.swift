import SwiftUI
import UIKit

/// Checks the iPhone's training pictures on the iPad. The pictures stay on the
/// iPhone: the iPad asks for one, shows it, and sends the answer back.
struct TrainingRemoteView: View {
    @EnvironmentObject var client: PhoneClient
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case loading
        case ball
        case framing
        case done
        case problem(String)
    }

    @State private var step = Step.loading
    @State private var itemID: String?
    @State private var image: UIImage?
    @State private var guess: NBox?
    @State private var confidence = 0.0
    @State private var box: NBox?
    @State private var zoom = ZoomCommand(kind: .whole, serial: 0)
    @State private var tapSize = 0.012
    @State private var pending = 0
    @State private var checked = 0
    @State private var askFraming = true
    @State private var nextAnswer: [String: Any]?   // what the iPhone sent after the last answer

    // Framing question
    @State private var answeredBall: NBox?
    @State private var players: [NBox] = []
    @State private var appFrame: NBox?
    @State private var chosenFrame: NBox?
    @State private var situation = PlaySituation.open
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                content
            }
            .padding(14)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await load(after: nil)
        }
    }

    private var title: String {
        switch step {
        case .framing: return "How would you frame it?"
        default: return pending > 0 ? "\(pending) pictures to check" : "Training pictures"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .loading:
            Spacer()
            ProgressView("Getting the picture from the iPhone…")
            Spacer()
        case .done:
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundColor(Theme.green)
            Text("All pictures are checked.")
                .font(.title2.weight(.semibold))
            Text("\(checked) checked pictures wait on the iPhone. Send them to the PC there: Settings > Training > Send checked pictures to the PC.")
                .multilineTextAlignment(.center)
                .foregroundColor(Theme.dim)
            Spacer()
        case .problem(let text):
            Spacer()
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(Theme.gold)
            Button("Try again") {
                Task { await load(after: nil) }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        case .ball:
            ballStep
        case .framing:
            framingStep
        }
    }

    // MARK: - Ball question

    @ViewBuilder
    private var ballStep: some View {
        if let picture = image?.cgImage, let id = itemID {
            HStack(spacing: 8) {
                if guess != nil {
                    Image(systemName: confidence < 0.55 ? "questionmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundColor(confidence < 0.55 ? Theme.gold : Theme.green)
                    Text(String(format: "Model's guess (yellow, dashed): %.0f %% sure", confidence * 100.0)
                         + (confidence < 0.55 ? ". Check it closely." : "."))
                } else {
                    Image(systemName: "eye.slash").foregroundColor(Theme.gold)
                    Text("The model found no ball. Draw a box if you can see one.")
                }
                Spacer()
                if let note = note {
                    Text(note).font(.caption).foregroundColor(Theme.dim)
                }
            }
            .font(.subheadline)
            BoxEditor(image: picture, imageID: id, guess: guess, box: $box, tapSize: tapSize, zoom: zoom)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text("One finger: draw a box, or drag it and its corners. Tap: put the box there. Pinch: zoom. Two fingers: move the picture. Double-tap: zoom in or out.")
                .font(.caption)
                .foregroundColor(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button {
                    zoom = ZoomCommand(kind: .whole, serial: zoom.serial + 1)
                } label: {
                    Label("Whole", systemImage: "arrow.down.right.and.arrow.up.left").frame(maxWidth: .infinity)
                }
                Button {
                    if let target = box ?? guess {
                        zoom = ZoomCommand(kind: .around(target), serial: zoom.serial + 1)
                    }
                } label: {
                    Label("Zoom to box", systemImage: "scope").frame(maxWidth: .infinity)
                }
                .disabled(box == nil && guess == nil)
                if box != nil {
                    Button(role: .destructive) {
                        box = nil
                    } label: {
                        Label("Clear", systemImage: "xmark").frame(maxWidth: .infinity)
                    }
                }
                Button {
                    Task { await load(after: id) }
                } label: {
                    Label("Later", systemImage: "forward").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            HStack(spacing: 10) {
                Button {
                    Task { await answer("noball", ball: nil) }
                } label: {
                    Label("No ball", systemImage: "circle.slash").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                Button {
                    Task { await answer("discard", ball: nil) }
                } label: {
                    Label("Throw away", systemImage: "trash").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(Theme.gold)
                Button {
                    if let ball = box ?? guess {
                        Task { await answer("ball", ball: ball) }
                    }
                } label: {
                    Label(box == nil && guess != nil ? "Guess is right" : "Ball is here",
                          systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.green)
                .disabled(box == nil && guess == nil)
            }
            .font(.headline)
            .disabled(busy)
        } else {
            Spacer()
            ProgressView()
            Spacer()
        }
    }

    // MARK: - Framing question

    @ViewBuilder
    private var framingStep: some View {
        if let picture = image {
            Text("Draw the frame you would have filmed (green). Yellow, dashed: what the app would show. Then pick what is happening.")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            FrameEditor(image: picture, players: players, ball: answeredBall, appFrame: appFrame, frame: $chosenFrame)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            SituationPicker(situation: $situation)
                .onChange(of: situation) { _, newValue in
                    Task { await changeSituation(newValue) }
                }
            Text("Drag: draw or move the frame. Pinch: tighter or wider. Tap: put the frame there.")
                .font(.caption)
                .foregroundColor(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button {
                    nextPicture()
                } label: {
                    Label("Skip", systemImage: "forward").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                Button {
                    chosenFrame = appFrame
                } label: {
                    Label("App's frame is right", systemImage: "hand.thumbsup").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(appFrame == nil)
                Button {
                    Task { await saveFrame() }
                } label: {
                    Label("Save frame", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.green)
                .disabled(chosenFrame == nil || busy)
            }
            .font(.headline)
        }
    }

    // MARK: - Talking to the iPhone

    private func load(after: String?) async {
        step = .loading
        guard let answer = await client.json("/train/next", after.map { [URLQueryItem(name: "after", value: $0)] } ?? []) else {
            step = .problem("The iPhone did not answer. Is RugbyCam open and the iPad remote on?")
            return
        }
        await show(answer)
    }

    /// Shows the picture an answer from the iPhone points to.
    private func show(_ answer: [String: Any]) async {
        pending = (answer["pending"] as? NSNumber)?.intValue ?? 0
        checked = (answer["checked"] as? NSNumber)?.intValue ?? 0
        askFraming = (answer["askFraming"] as? Bool) ?? true
        guard let id = answer["id"] as? String else {
            step = .done
            return
        }
        guard let picture = await client.trainingImage(id) else {
            step = .problem("The picture could not be loaded from the iPhone.")
            return
        }
        itemID = id
        image = picture
        guess = NBox(any: answer["guess"])
        confidence = (answer["confidence"] as? NSNumber)?.doubleValue ?? 0
        box = nil
        let kind: ZoomCommand.Kind = guess.map { ZoomCommand.Kind.around($0) } ?? ZoomCommand.Kind.whole
        zoom = ZoomCommand(kind: kind, serial: zoom.serial + 1)
        step = .ball
    }

    private func answer(_ kind: String, ball: NBox?) async {
        guard let id = itemID else { return }
        busy = true
        defer { busy = false }
        var items = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "a", value: kind)]
        if let ball = ball {
            items += ball.queryItems
            tapSize = min(max(ball.w, 0.003), 0.08)
        }
        guard let reply = await client.json("/train/answer", items) else {
            note = "The iPhone did not answer. Try again."
            return
        }
        note = reply["error"] as? String
        nextAnswer = reply
        if askFraming && kind != "discard" {
            await startFraming(id: id, ball: ball)
        } else {
            await show(reply)
        }
    }

    private func startFraming(id: String, ball: NBox?) async {
        answeredBall = ball
        chosenFrame = nil
        appFrame = nil
        players = []
        step = .framing
        var items = [URLQueryItem(name: "id", value: id)]
        if let ball = ball {
            items += ball.queryItems.map { URLQueryItem(name: "b" + $0.name, value: $0.value) }
        }
        if let reply = await client.json("/train/framing", items, timeout: 12.0) {
            apply(framing: reply)
        }
    }

    private func apply(framing reply: [String: Any]) {
        players = ((reply["players"] as? [Any]) ?? []).compactMap { NBox(any: $0) }
        appFrame = NBox(any: reply["appFrame"])
        if let key = reply["situation"] as? String, let found = PlaySituation(rawValue: key), found != situation {
            situation = found
        }
    }

    private func changeSituation(_ newValue: PlaySituation) async {
        guard let id = itemID else { return }
        if let reply = await client.json("/train/situation", [URLQueryItem(name: "id", value: id),
                                                              URLQueryItem(name: "sit", value: newValue.rawValue)]) {
            players = ((reply["players"] as? [Any]) ?? []).compactMap { NBox(any: $0) }
            appFrame = NBox(any: reply["appFrame"])
        }
    }

    private func saveFrame() async {
        guard let id = itemID, let frame = chosenFrame else { return }
        busy = true
        defer { busy = false }
        var items = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "sit", value: situation.rawValue)]
        items += frame.queryItems
        if let reply = await client.json("/train/saveframe", items) {
            note = reply["note"] as? String
        }
        nextPicture()
    }

    private func nextPicture() {
        let reply = nextAnswer
        nextAnswer = nil
        Task {
            if let reply = reply {
                await show(reply)
            } else {
                await load(after: nil)
            }
        }
    }
}
