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

    /// Kalibratie uit de detecties, robuust tegen verwisselde labels (RANSAC).
    ///
    /// Het meegeleverde model verwart soms links/rechts (bv. punt 8|11 gelabeld als "15").
    /// Daarom: per label tot 3 kandidaten, alle combinaties van 4 labels proberen, en de homografie
    /// kiezen waarbij de meeste detecties op hun verwachte plek vallen. Daarna kleinste kwadraten op
    /// enkel die "inliers". Geeft de 4 standaardpunten van de app (volgorde BoardGeometry.calibrationAnglesDeg).
    static func calibrationPoints(_ detections: [Detection], labels: Labels = Labels(),
                                  minConfidence: Double = 0.5, toleranceMM: Double = 12) -> [CGPoint]? {
        func mm(_ name: String) -> CGPoint {
            let a = labels.calibration[name]! * .pi / 180
            return CGPoint(x: BoardGeometry.doubleOutR * cos(a), y: BoardGeometry.doubleOutR * sin(a))
        }
        // Kandidaten per label (sterkste eerst). Zwakkere kandidaten mogen meedoen als reserve.
        var cands: [String: [Detection]] = [:]
        for d in detections where labels.calibration[d.label] != nil && d.confidence >= minConfidence * 0.4 {
            cands[d.label, default: []].append(d)
        }
        for k in cands.keys { cands[k] = Array(cands[k]!.sorted { $0.confidence > $1.confidence }.prefix(3)) }
        let names = cands.keys.sorted()
        guard names.count >= 4 else { return nil }

        var bestScore = -1.0
        var bestInliers: [(CGPoint, CGPoint)] = []
        // Alle 4-tallen van labels × kandidaatkeuzes
        func subsets(_ k: Int, _ start: Int, _ cur: [String], _ out: inout [[String]]) {
            if cur.count == k { out.append(cur); return }
            for i in start..<names.count { subsets(k, i + 1, cur + [names[i]], &out) }
        }
        var quads: [[String]] = []
        subsets(4, 0, [], &quads)
        for quad in quads {
            var choices: [[Detection]] = [[]]
            for n in quad { choices = choices.flatMap { c in cands[n]!.map { c + [$0] } } }
            for pick in choices {
                // Moet minstens één sterke detectie bevatten
                guard pick.contains(where: { $0.confidence >= minConfidence }),
                      let H = Homography(from: quad.map(mm), to: pick.map(\.point)), let inv = H.inverse else { continue }
                // Inliers: per label de beste kandidaat die op zijn verwachte plek valt
                var score = 0.0
                var inl: [(CGPoint, CGPoint)] = []
                for n in names {
                    let target = mm(n)
                    let best = cands[n]!.map { d -> (Detection, Double) in
                        let q = inv.apply(d.point)
                        return (d, hypot(Double(q.x - target.x), Double(q.y - target.y)))
                    }.filter { $0.1 <= toleranceMM }.max { $0.0.confidence < $1.0.confidence }
                    if let (d, _) = best { score += d.confidence; inl.append((target, d.point)) }
                }
                if score > bestScore { bestScore = score; bestInliers = inl }
            }
        }
        guard bestInliers.count >= 4,
              let toImage = Homography(leastSquaresFrom: bestInliers.map(\.0), to: bestInliers.map(\.1)) else { return nil }
        return BoardGeometry.calibrationPointsMM.map(toImage.apply)
    }

    /// Alle pijlpunten, dubbele detecties (binnen `mergeDistance` px) samengevoegd.
    static func dartTips(_ detections: [Detection], labels: Labels = Labels(),
                         minConfidence: Double = 0.2, mergeDistance: Double = 6) -> [Detection] {
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
    /// - hint: punt (mm) uit de frame-difference (waar de verandering zat). Kan aan het verkeerde
    ///   uiteinde van de pijl liggen (camera recht ervoor → flight-kant), vandaar de ruime straal (80 mm).
    /// - Returns: beste punt in mm, of nil als YOLO de nieuwe pijl niet (betrouwbaar) zag.
    static func newDartPoint(candidates: [Detection], known: [CGPoint], hint: CGPoint?,
                             toBoard: Homography,
                             knownToleranceMM: Double = 8, hintToleranceMM: Double = 80,
                             region: CGRect? = nil, regionMarginPx: Double = 0) -> CGPoint? {
        // Beste methode: het punt moet OP de vlek van de nieuwe pijl liggen (beeldpixels).
        // De geschatte punt (hint) zit bij een camera recht ervoor soms aan de flight-kant.
        if let region {
            func distance(_ p: CGPoint) -> Double {
                let dx = max(Double(region.minX) - Double(p.x), 0, Double(p.x) - Double(region.maxX))
                let dy = max(Double(region.minY) - Double(p.y), 0, Double(p.y) - Double(region.maxY))
                return hypot(dx, dy)
            }
            let fresh = candidates.filter { c in
                let mm = toBoard.apply(c.point)
                return !known.contains { hypot(Double($0.x - mm.x), Double($0.y - mm.y)) < knownToleranceMM }
                    && hypot(Double(mm.x), Double(mm.y)) < BoardGeometry.doubleOutR * 1.3
            }
            // Dichtst bij de vlek; bij gelijke afstand (bv. allebei erop) de sterkste.
            let scored = fresh.map { (det: $0, score: distance($0.point) - $0.confidence) }
            guard let best = scored.min(by: { $0.score < $1.score }),
                  distance(best.det.point) <= regionMarginPx else { return nil }
            return toBoard.apply(best.det.point)
        }
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
