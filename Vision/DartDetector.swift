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

    /// NMS-instellingen van het model (zitten als invoer in het geëxporteerde .mlpackage).
    struct Thresholds {
        /// Laag houden: de multi-frame consensus filtert de twijfelgevallen er toch uit.
        var confidence = 0.20
        /// HOOG voor pijlen dicht bij elkaar (bv. 3 in T20): keypoint-vakjes overlappen sterk,
        /// met 0.45 zou NMS de tweede pijl wegfilteren. Dubbele detecties van dezelfde pijl
        /// worden daarna samengevoegd binnen 6 px (YoloInterpreter.dartTips).
        var iou = 0.65
    }

    let labels: YoloInterpreter.Labels
    let source: Source
    private let model: VNCoreMLModel

    init?(labels: YoloInterpreter.Labels = .init(), thresholds: Thresholds = .init()) {
        // Eerst het zelf geïmporteerde model; lukt dat niet (kapot/onvolledig), dan het meegeleverde.
        var candidates: [(URL, Source)] = []
        if FileManager.default.fileExists(atPath: Self.customModelURL.path) {
            candidates.append((Self.customModelURL, .custom))
        }
        if let bundled = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") {
            candidates.append((bundled, .bundled))
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all                     // Neural Engine waar mogelijk
        // Eerste model dat laadt (let-eigenschappen pas daarna één keer toewijzen).
        var loaded: (VNCoreMLModel, Source)?
        for (url, src) in candidates where loaded == nil {
            if let ml = try? MLModel(contentsOf: url, configuration: config),
               let vn = try? VNCoreMLModel(for: ml) {
                loaded = (vn, src)
            }
        }
        guard let (vn, src) = loaded else { return nil }
        vn.featureProvider = try? MLDictionaryFeatureProvider(dictionary: [
            "confidenceThreshold": thresholds.confidence,
            "iouThreshold": thresholds.iou,
        ])
        self.labels = labels
        self.source = src
        self.model = vn
    }

    /// Zoekt in een UITSNEDE rond de nieuwe pijl, op ware grootte (niet opgeschaald), in het midden van een
    /// grijs 800×800-vlak. Het model is getraind op hele borden van 800 px: zo blijft de pijl even groot als
    /// tijdens de training én ziet het model enkel de nieuwe pijl. Getest op echte video's: 9/9 i.p.v. 7/9.
    /// - Parameters:
    ///   - image: bord-uitsnede geschaald naar 800 px breed (zoals bij de training)
    ///   - patch: rechthoek in `image` (pixels, linksboven)
    /// - Returns: detecties in pixels van `image`
    func detect(in image: CGImage, patch: CGRect) -> [Detection] {
        let n = 800
        guard let sub = image.cropping(to: patch.integral), sub.width <= n, sub.height <= n,
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        ctx.setFillColor(CGColor(red: 114 / 255, green: 114 / 255, blue: 114 / 255, alpha: 1))   // YOLO-grijs
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let ox = (n - sub.width) / 2, oy = (n - sub.height) / 2
        // Core Graphics tekent met oorsprong linksonder: y omdraaien zodat de uitsnede op rij `oy` begint.
        ctx.draw(sub, in: CGRect(x: ox, y: n - oy - sub.height, width: sub.width, height: sub.height))
        guard let canvas = ctx.makeImage() else { return [] }
        let origin = patch.integral.origin
        return detect(in: canvas).compactMap { d in
            let px = d.point.x - CGFloat(ox), py = d.point.y - CGFloat(oy)
            guard px >= 0, py >= 0, px < CGFloat(sub.width), py < CGFloat(sub.height) else { return nil }
            return Detection(label: d.label, point: CGPoint(x: origin.x + px, y: origin.y + py), confidence: d.confidence)
        }
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
