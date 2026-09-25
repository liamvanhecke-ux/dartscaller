import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Eén detectie van het YOLO-model, omgerekend naar beeldpixels (linksboven).
/// DeepDarts-stijl: elk keypoint (pijlpunt of kalibratiepunt) is een klein vakje; het middelpunt = het punt.
struct Detection: Equatable {
    let label: String
    let point: CGPoint
    let confidence: Double
}

/// Vertaalt ruwe YOLO-detecties naar kalibratie en pijlpunten. Platformonafhankelijk en getest.
enum YoloInterpreter {

    struct Labels {
        /// Klassenaam → hoek (graden, board-coördinaten) van het kalibratiepunt op de buitenrand van de double-ring.
        /// Standaard = het meegeleverde Dart Sense-model: "20" = draad 5|20, "6" = 13|6, "3" = 17|3,
        /// "11" = 8|11, plus 2 extra punten "9" = 14|9 en "15" = 10|15.
        var calibration: [String: Double] = ["20": 99, "6": 9, "3": -81, "11": -171, "9": 153, "15": -27]
        /// Klassenamen die een pijlpunt betekenen.
        var dart: Set<String> = ["dart", "tip", "dart_tip"]
    }

    /// Kalibratie uit de detecties: gebruikt ALLE gevonden kalibratiepunten (min. 4, kleinste kwadraten)
    /// en geeft de 4 standaardpunten van de app terug (volgorde BoardGeometry.calibrationAnglesDeg).
    /// nil als er minder dan 4 betrouwbare punten zijn.
    static func calibrationPoints(_ detections: [Detection], labels: Labels = Labels(),
                                  minConfidence: Double = 0.5) -> [CGPoint]? {
        var image: [CGPoint] = [], board: [CGPoint] = []
        for (name, deg) in labels.calibration.sorted(by: { $0.key < $1.key }) {
            guard let best = detections
                .filter({ $0.label == name && $0.confidence >= minConfidence })
                .max(by: { $0.confidence < $1.confidence }) else { continue }
            let a = deg * .pi / 180
            image.append(best.point)
            board.append(CGPoint(x: BoardGeometry.doubleOutR * cos(a), y: BoardGeometry.doubleOutR * sin(a)))
        }
        guard image.count >= 4,
              let toImage = Homography(leastSquaresFrom: board, to: image) else { return nil }
        return BoardGeometry.calibrationPointsMM.map(toImage.apply)
    }

    /// Alle pijlpunten, dubbele detecties (binnen `mergeDistance` px) samengevoegd.
    static func dartTips(_ detections: [Detection], labels: Labels = Labels(),
                         minConfidence: Double = 0.3, mergeDistance: Double = 6) -> [Detection] {
        let darts = detections
            .filter { labels.dart.contains($0.label) && $0.confidence >= minConfidence }
            .sorted { $0.confidence > $1.confidence }
        var kept: [Detection] = []
        for d in darts where !kept.contains(where: { distance($0.point, d.point) < mergeDistance }) {
            kept.append(d)
        }
        return kept
    }

    /// Kiest de pijlpunt van de NIEUWE pijl.
    /// - candidates: YOLO-pijlpunten (beeldpixels)
    /// - known: punten (mm) van pijlen die deze beurt al geteld zijn → worden overgeslagen
    /// - hint: punt (mm) uit de frame-difference (waar de verandering zat)
    /// - Returns: beste punt in mm, of nil als YOLO de nieuwe pijl niet (betrouwbaar) zag.
    static func newDartPoint(candidates: [Detection], known: [CGPoint], hint: CGPoint?,
                             toBoard: Homography,
                             knownToleranceMM: Double = 8, hintToleranceMM: Double = 30) -> CGPoint? {
        let fresh = candidates
            .map { (mm: toBoard.apply($0.point), conf: $0.confidence) }
            .filter { c in !known.contains { distance($0, c.mm) < knownToleranceMM } }
            .filter { hypot(Double($0.mm.x), Double($0.mm.y)) < BoardGeometry.doubleOutR * 1.3 }
        guard !fresh.isEmpty else { return nil }
        guard let hint else {
            return fresh.count == 1 ? fresh[0].mm : nil      // zonder hint alleen als het eenduidig is
        }
        let nearest = fresh.min { distance($0.mm, hint) < distance($1.mm, hint) }!
        return distance(nearest.mm, hint) <= hintToleranceMM ? nearest.mm : nil
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(a.x - b.x), Double(a.y - b.y))
    }
}
