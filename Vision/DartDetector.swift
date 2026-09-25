import CoreML
import CoreGraphics
import Vision

/// YOLO-model (Core ML) dat pijlpunten en de 4 kalibratiepunten vindt.
/// Zet `DartsYOLO.mlpackage` in het Xcode-project; Xcode compileert het naar `DartsYOLO.mlmodelc`.
/// Geen model aanwezig → init geeft nil en de app gebruikt de frame-difference-heuristiek.
final class DartDetector {

    static let modelName = "DartsYOLO"

    /// Zelf geïmporteerd (hertraind) model; heeft voorrang op het meegeleverde.
    static var customModelURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models/\(modelName).mlmodelc", isDirectory: true)
    }

    enum Source: String { case custom = "Eigen model", bundled = "Meegeleverd model" }

    let labels: YoloInterpreter.Labels
    let source: Source
    private let model: VNCoreMLModel

    init?(labels: YoloInterpreter.Labels = .init()) {
        let custom = Self.customModelURL
        let url: URL
        if FileManager.default.fileExists(atPath: custom.path) {
            url = custom
            source = .custom
        } else if let bundled = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") {
            url = bundled
            source = .bundled
        } else {
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all                     // Neural Engine waar mogelijk
        guard let ml = try? MLModel(contentsOf: url, configuration: config),
              let vn = try? VNCoreMLModel(for: ml) else { return nil }
        self.labels = labels
        self.model = vn
    }

    /// Detecties in pixels van `image` (oorsprong linksboven).
    /// Vereist een model geëxporteerd MET nms=True (anders geen VNRecognizedObjectObservation).
    func detect(in image: CGImage) -> [Detection] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let results = request.results as? [VNRecognizedObjectObservation] else { return [] }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return results.compactMap { obs in
            guard let top = obs.labels.first else { return nil }
            let b = obs.boundingBox                    // genormaliseerd, oorsprong linksonder
            return Detection(label: top.identifier,
                             point: CGPoint(x: b.midX * w, y: (1 - b.midY) * h),
                             confidence: Double(top.confidence))
        }
    }
}
