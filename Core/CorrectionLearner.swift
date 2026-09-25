import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Leert tijdens het spelen waar de detectie systematisch naast zit (bv. "rond T20 altijd 5 mm te laag"),
/// en schuift volgende detecties bij.
///
/// - Correctie (T20 → S20): de echte pijl lag in S20 → leer de verschuiving naar het dichtste punt in S20.
/// - Gewone worp zonder correctie: bevestigt de huidige verschuiving (lichter gewicht).
///
/// Lokaal (per zone van het bord) + globaal (overal), recente worpen tellen zwaarder.
struct CorrectionLearner: Codable, Equatable {

    struct Observation: Codable, Equatable {
        var x: Double, y: Double        // ruwe detectie (mm)
        var dx: Double, dy: Double      // gewenste verschuiving (mm)
        var weight: Double
        var corrected: Bool
    }

    private(set) var observations: [Observation] = []

    var maxObservations = 400
    /// Hoe ver een observatie "doorwerkt" op het bord (mm).
    var bandwidthMM = 35.0
    /// Terughoudendheid: hoeveel data nodig is voor volle correctie.
    var localPrior = 1.5
    var globalPrior = 3.0
    /// Maximale verschuiving (veiligheidsgrens).
    var maxShiftMM = 10.0
    /// Oudere observaties wegen minder (per nieuwe observatie).
    var decay = 0.995

    var correctionCount: Int { observations.filter(\.corrected).count }
    var confirmationCount: Int { observations.filter { !$0.corrected }.count }

    // MARK: Toepassen

    func correction(at p: CGPoint) -> Vector2D {
        guard !observations.isEmpty else { return Vector2D(dx: 0, dy: 0) }
        let px = Double(p.x), py = Double(p.y)
        var gx = 0.0, gy = 0.0, gw = 0.0
        var lx = 0.0, ly = 0.0, lw = 0.0
        let n = observations.count
        for (i, o) in observations.enumerated() {
            let w = o.weight * pow(decay, Double(n - 1 - i))
            gx += w * o.dx; gy += w * o.dy; gw += w
            let d2 = (o.x - px) * (o.x - px) + (o.y - py) * (o.y - py)
            let k = w * exp(-d2 / (2 * bandwidthMM * bandwidthMM))
            lx += k * o.dx; ly += k * o.dy; lw += k
        }
        let globalX = gx / (gw + globalPrior), globalY = gy / (gw + globalPrior)
        var cx = (lx + localPrior * globalX) / (lw + localPrior)
        var cy = (ly + localPrior * globalY) / (lw + localPrior)
        let len = hypot(cx, cy)
        if len > maxShiftMM { cx *= maxShiftMM / len; cy *= maxShiftMM / len }
        return Vector2D(dx: cx, dy: cy)
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let c = correction(at: p)
        return CGPoint(x: Double(p.x) + c.dx, y: Double(p.y) + c.dy)
    }

    // MARK: Leren

    /// Worp zonder correctie: de getoonde positie was goed genoeg.
    mutating func observeConfirmed(raw: CGPoint, shown: CGPoint) {
        add(Observation(x: Double(raw.x), y: Double(raw.y),
                        dx: Double(shown.x - raw.x), dy: Double(shown.y - raw.y),
                        weight: 0.3, corrected: false))
    }

    /// Worp gecorrigeerd naar `correct`. Geeft het (benaderde) echte punt terug, handig als trainingslabel.
    @discardableResult
    mutating func observeCorrected(raw: CGPoint, shown: CGPoint, correct: DartHit) -> CGPoint {
        let target = Self.nearestPoint(in: correct, to: shown)
        add(Observation(x: Double(raw.x), y: Double(raw.y),
                        dx: Double(target.x - raw.x), dy: Double(target.y - raw.y),
                        weight: 1.0, corrected: true))
        return target
    }

    mutating func reset() { observations = [] }

    private mutating func add(_ o: Observation) {
        observations.append(o)
        if observations.count > maxObservations { observations.removeFirst(observations.count - maxObservations) }
    }

    // MARK: Geometrie

    /// Dichtste punt binnen het vak van `hit` (met `marginMM` afstand tot de draden).
    static func nearestPoint(in hit: DartHit, to p: CGPoint, marginMM m: Double = 2) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        var r = hypot(x, y)
        var theta = r > 1e-9 ? atan2(y, x) * 180 / .pi : BoardGeometry.centerAngle(of: hit.segment)

        func polar(_ r: Double, _ deg: Double) -> CGPoint {
            CGPoint(x: r * cos(deg * .pi / 180), y: r * sin(deg * .pi / 180))
        }

        switch (hit.segment, hit.multiplier) {
        case (_, 0):
            return polar(max(r, BoardGeometry.doubleOutR + m), theta)
        case (25, 2):
            return r <= BoardGeometry.bullR - m ? p : polar(BoardGeometry.bullR - m, theta)
        case (25, _):
            return polar(min(max(r, BoardGeometry.bullR + m), BoardGeometry.outerBullR - m), theta)
        default:
            let bands: [(Double, Double)]
            switch hit.multiplier {
            case 3: bands = [(BoardGeometry.trebleInR, BoardGeometry.trebleOutR)]
            case 2: bands = [(BoardGeometry.doubleInR, BoardGeometry.doubleOutR)]
            default: bands = [(BoardGeometry.outerBullR, BoardGeometry.trebleInR),
                              (BoardGeometry.trebleOutR, BoardGeometry.doubleInR)]
            }
            let clamped = bands.map { min(max(r, $0.0 + m), $0.1 - m) }
            r = clamped.min { abs($0 - r) < abs($1 - r) }!

            let center = BoardGeometry.centerAngle(of: hit.segment)
            var d = (theta - center).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            let half = 9 - (m / r) * 180 / .pi
            theta = center + min(max(d, -half), half)
            return polar(r, theta)
        }
    }
}
