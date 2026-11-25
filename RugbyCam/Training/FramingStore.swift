import Foundation

/// Keeps the framing examples the person showed (boxes drawn while filming and
/// on training pictures) and what the zoom has learned from them.
///
///   Documents/Training/framing/examples.jsonl   one example per line
///   Documents/Training/framing/learned.json     the learned framing per situation
///
/// Main thread only.
final class FramingStore: ObservableObject {
    @Published private(set) var learned: [String: LearnedFrame] = [:]
    @Published private(set) var exampleCount = 0

    let folder: URL
    private let queue = DispatchQueue(label: "rugbycam.framing")

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = documents.appendingPathComponent("Training/framing", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: learnedURL),
           let saved = try? JSONDecoder().decode([String: LearnedFrame].self, from: data) {
            learned = saved
        }
        if let text = try? String(contentsOf: examplesURL, encoding: .utf8) {
            exampleCount = text.split(separator: "\n").count
        }
    }

    var examplesURL: URL { folder.appendingPathComponent("examples.jsonl") }
    private var learnedURL: URL { folder.appendingPathComponent("learned.json") }

    /// Saves one example and learns from it. Returns a short text for the screen.
    @discardableResult
    func add(_ example: FramingExample) -> String {
        exampleCount += 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(example), var line = String(data: data, encoding: .utf8) {
            line += "\n"
            let url = examplesURL
            queue.async {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(Data(line.utf8))
                    try? handle.close()
                } else {
                    try? Data(line.utf8).write(to: url, options: .atomic)
                }
            }
        }

        guard let action = example.action,
              let lesson = FramingMath.lesson(action: action, chosen: example.chosenFrame) else {
            return "Saved. (No players were found, so the zoom could not learn from this one.)"
        }
        var memory = learned[example.situation.rawValue] ?? LearnedFrame(fill: lesson.fill, offsetX: lesson.offsetX, count: 0)
        memory.count += 1
        // A running average; after a dozen examples newer ones count a little more.
        let step = 1.0 / Double(min(memory.count, 12))
        memory.fill += (lesson.fill - memory.fill) * step
        memory.offsetX += (lesson.offsetX - memory.offsetX) * step
        learned[example.situation.rawValue] = memory
        saveLearned()
        return "Learned for \(example.situation.label.lowercased()) (\(memory.count) examples)."
    }

    /// Forgets what was learned (the saved examples stay, for training on the PC).
    func resetLearned() {
        learned = [:]
        saveLearned()
    }

    /// A line per situation for the settings screen.
    var summary: [String] {
        return PlaySituation.choosable.compactMap { situation in
            guard let memory = learned[situation.rawValue], memory.count > 0 else { return nil }
            let side: String
            if memory.offsetX > 0.04 {
                side = ", more room on the right"
            } else if memory.offsetX < -0.04 {
                side = ", more room on the left"
            } else {
                side = ""
            }
            return "\(situation.label): action fills \(Int((memory.fill * 100).rounded())) %\(side) · \(memory.count) examples"
        }
    }

    private func saveLearned() {
        let snapshot = learned
        let url = learnedURL
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
