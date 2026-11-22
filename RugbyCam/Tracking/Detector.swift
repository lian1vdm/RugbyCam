import CoreImage
import CoreML
import Foundation
import Vision

struct DetectedObject {
    var box: NBox
    var confidence: Double
    var label: String
}

enum DetectorError: LocalizedError {
    case noImageInput
    case unsupportedOutput

    var errorDescription: String? {
        switch self {
        case .noImageInput:
            return "This model has no image input."
        case .unsupportedOutput:
            return "This model does not report boxes. Export it again with nms=True (see tools/export_coreml.py)."
        }
    }
}

/// Runs a Core ML object-detection model (exported from YOLO with nms=True)
/// on a part of the picture and returns boxes in whole-picture coordinates.
final class ObjectDetector {
    let inputWidth: Int
    let inputHeight: Int
    let sourceName: String

    private let request: VNCoreMLRequest

    /// Width divided by height of the picture the model expects.
    var aspect: Double {
        return Double(inputWidth) / Double(max(inputHeight, 1))
    }

    init(model: LoadedModel, confidenceThreshold: Double, overlapThreshold: Double) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let mlModel = try MLModel(contentsOf: model.compiledURL, configuration: configuration)

        var width = 0
        var height = 0
        let inputs = mlModel.modelDescription.inputDescriptionsByName
        for description in inputs.values {
            if let constraint = description.imageConstraint {
                width = constraint.pixelsWide
                height = constraint.pixelsHigh
            }
        }
        guard width > 0, height > 0 else {
            throw DetectorError.noImageInput
        }
        inputWidth = width
        inputHeight = height
        sourceName = model.sourceName

        let visionModel = try VNCoreMLModel(for: mlModel)
        // YOLO exports with nms=True take their thresholds as extra inputs.
        var thresholds: [String: Any] = [:]
        if inputs["confidenceThreshold"] != nil {
            thresholds["confidenceThreshold"] = confidenceThreshold
        }
        if inputs["iouThreshold"] != nil {
            thresholds["iouThreshold"] = overlapThreshold
        }
        if !thresholds.isEmpty {
            visionModel.featureProvider = try MLDictionaryFeatureProvider(dictionary: thresholds)
        }

        let newRequest = VNCoreMLRequest(model: visionModel)
        // The search area always has the model's own shape, so stretching to fill does not distort it.
        newRequest.imageCropAndScaleOption = .scaleFill
        request = newRequest
    }

    /// Looks for objects inside `area` (a part of the whole picture).
    func detect(in image: CIImage, area: NBox) throws -> [DetectedObject] {
        // Core Image puts the origin at the bottom left, the app at the top left.
        let extent = image.extent
        let cropRect = CGRect(x: extent.minX + CGFloat(area.x) * extent.width,
                              y: extent.minY + CGFloat(1.0 - area.y - area.h) * extent.height,
                              width: CGFloat(area.w) * extent.width,
                              height: CGFloat(area.h) * extent.height)
        let cropped = image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

        let handler = VNImageRequestHandler(ciImage: cropped, orientation: .up, options: [:])
        try handler.perform([request])
        guard let results = request.results, !results.isEmpty else {
            return []
        }
        guard let observations = results as? [VNRecognizedObjectObservation] else {
            throw DetectorError.unsupportedOutput
        }
        var found: [DetectedObject] = []
        for observation in observations {
            // Vision's boxes are relative to the cropped picture, origin bottom left.
            let rect = observation.boundingBox
            let localTop = 1.0 - Double(rect.maxY)
            let box = NBox(x: area.x + Double(rect.minX) * area.w,
                           y: area.y + localTop * area.h,
                           w: Double(rect.width) * area.w,
                           h: Double(rect.height) * area.h)
            let label = observation.labels.first?.identifier ?? ""
            found.append(DetectedObject(box: box, confidence: Double(observation.confidence), label: label))
        }
        return found
    }
}

/// Finds people with the detector that is built into iOS (no model file needed).
final class HumanDetector {
    private let request: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        return request
    }()

    func detect(in pixelBuffer: CVPixelBuffer) throws -> [NBox] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        var boxes: [NBox] = []
        for observation in request.results ?? [] {
            let rect = observation.boundingBox
            boxes.append(NBox(x: Double(rect.minX),
                              y: 1.0 - Double(rect.maxY),
                              w: Double(rect.width),
                              h: Double(rect.height)))
        }
        return boxes
    }
}

struct LoadedModel {
    var compiledURL: URL
    var sourceName: String
}

/// Finds model files. A model copied into the app's folder in the Files app
/// (On My iPhone > RugbyCam) wins over one built into the app.
enum ModelStore {
    static let ballNames = ["BallDetector", "best"]
    static let playerNames = ["PlayerDetector"]

    static func find(names: [String]) throws -> LoadedModel? {
        let files = FileManager.default
        let documents = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for base in names {
            for fileExtension in ["mlmodelc", "mlpackage", "mlmodel"] {
                let candidate = documents.appendingPathComponent("\(base).\(fileExtension)")
                guard files.fileExists(atPath: candidate.path) else {
                    continue
                }
                if fileExtension == "mlmodelc" {
                    return LoadedModel(compiledURL: candidate, sourceName: candidate.lastPathComponent)
                }
                let compiled = try compile(candidate)
                return LoadedModel(compiledURL: compiled, sourceName: candidate.lastPathComponent)
            }
            if let bundled = Bundle.main.url(forResource: base, withExtension: "mlmodelc") {
                return LoadedModel(compiledURL: bundled, sourceName: "\(base) (built into the app)")
            }
        }
        return nil
    }

    /// Core ML has to compile a model once before it can run. The result is kept,
    /// so this only takes time the first time a new model file is seen.
    private static func compile(_ source: URL) throws -> URL {
        let files = FileManager.default
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("CompiledModels", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)

        let attributes = try files.attributesOfItem(atPath: source.path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0.0
        let name = source.deletingPathExtension().lastPathComponent
        let cached = folder.appendingPathComponent("\(name)-\(Int(modified)).mlmodelc", isDirectory: true)
        if files.fileExists(atPath: cached.path) {
            return cached
        }
        if let existing = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for item in existing where item.lastPathComponent.hasPrefix("\(name)-") {
                try? files.removeItem(at: item)
            }
        }
        let temporary = try MLModel.compileModel(at: source)
        do {
            try files.moveItem(at: temporary, to: cached)
        } catch {
            try files.copyItem(at: temporary, to: cached)
        }
        return cached
    }
}
