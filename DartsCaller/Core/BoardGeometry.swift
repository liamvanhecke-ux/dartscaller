import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Eén geworpen pijl

struct DartHit: Identifiable, Codable, Equatable {
    var id = UUID()
    /// 1...20, 25 = bull, 0 = mis
    var segment: Int
    /// 0 = mis, 1 = single, 2 = double, 3 = triple. Bullseye = segment 25 × 2.
    var multiplier: Int
    /// Positie in mm t.o.v. het middelpunt (x rechts, y omhoog). nil bij handmatige invoer.
    var boardPoint: CGPoint?

    init(segment: Int, multiplier: Int, boardPoint: CGPoint? = nil) {
        precondition(DartHit.isValid(segment: segment, multiplier: multiplier), "Ongeldige worp \(multiplier)×\(segment)")
        self.segment = segment
        self.multiplier = multiplier
        self.boardPoint = boardPoint
    }

    static func isValid(segment: Int, multiplier: Int) -> Bool {
        switch (segment, multiplier) {
        case (0, 0): return true
        case (1...20, 1...3): return true
        case (25, 1...2): return true
        default: return false
        }
    }

    static var miss: DartHit { DartHit(segment: 0, multiplier: 0) }
    static func single(_ s: Int) -> DartHit { DartHit(segment: s, multiplier: 1) }
    static func double(_ s: Int) -> DartHit { DartHit(segment: s, multiplier: 2) }
    static func triple(_ s: Int) -> DartHit { DartHit(segment: s, multiplier: 3) }
    static var outerBull: DartHit { DartHit(segment: 25, multiplier: 1) }
    static var bull: DartHit { DartHit(segment: 25, multiplier: 2) }

    var score: Int { segment * multiplier }
    var isMiss: Bool { multiplier == 0 }
    /// Telt als finish-dart bij double-out (bullseye inbegrepen).
    var isDouble: Bool { multiplier == 2 }

    /// Afstand tot het exacte middelpunt in mm (bull-off). nil = geen positie bekend.
    var distanceToCenterMM: Double? {
        boardPoint.map { hypot(Double($0.x), Double($0.y)) }
    }

    /// Korte notatie voor de UI: "T20", "D16", "S5", "BULL", "25", "MIS"
    var shortLabel: String {
        switch (segment, multiplier) {
        case (_, 0): return "MIS"
        case (25, 2): return "BULL"
        case (25, 1): return "25"
        case (let s, 3): return "T\(s)"
        case (let s, 2): return "D\(s)"
        case (let s, _): return "S\(s)"
        }
    }

    /// Gelijkheid op waarde (niet op id / positie) — handig in tests en correcties.
    func sameValue(as other: DartHit) -> Bool {
        segment == other.segment && multiplier == other.multiplier
    }
}

// MARK: - Standaard dartbord (WDF/BDO/PDC-maten in mm)

enum BoardGeometry {
    /// Segmenten met de klok mee, beginnend bovenaan.
    static let order = [20, 1, 18, 4, 13, 6, 10, 15, 2, 17, 3, 19, 7, 16, 8, 11, 14, 9, 12, 5]

    static let bullR       = 6.35
    static let outerBullR  = 15.9
    static let trebleInR   = 99.0
    static let trebleOutR  = 107.0
    static let doubleInR   = 162.0
    static let doubleOutR  = 170.0

    /// Middenhoek (graden, 0° = rechts, tegen de klok in) van een segment.
    static func centerAngle(of segment: Int) -> Double {
        guard let i = order.firstIndex(of: segment) else { return 90 }
        return 90 - Double(i) * 18
    }

    /// Zet een punt in mm om naar een worp.
    static func hit(at p: CGPoint) -> DartHit {
        let x = Double(p.x), y = Double(p.y)
        let r = hypot(x, y)
        if r <= bullR      { return DartHit(segment: 25, multiplier: 2, boardPoint: p) }
        if r <= outerBullR { return DartHit(segment: 25, multiplier: 1, boardPoint: p) }
        if r >  doubleOutR { return DartHit(segment: 0,  multiplier: 0, boardPoint: p) }

        let angle = atan2(y, x) * 180 / .pi
        // Segment 20 loopt van 81° tot 99°. Tel met de klok mee vanaf 99°.
        var fromEdge = (99 - angle).truncatingRemainder(dividingBy: 360)
        if fromEdge < 0 { fromEdge += 360 }
        let index = min(19, Int(fromEdge / 18))
        let segment = order[index]

        let multiplier: Int
        if r >= trebleInR && r <= trebleOutR { multiplier = 3 }
        else if r >= doubleInR { multiplier = 2 }
        else { multiplier = 1 }
        return DartHit(segment: segment, multiplier: multiplier, boardPoint: p)
    }

    /// Een representatief punt (mm) voor een handmatig ingevoerde worp, om hem op het virtuele bord te tekenen.
    static func representativePoint(for hit: DartHit) -> CGPoint? {
        switch (hit.segment, hit.multiplier) {
        case (0, _):  return nil
        case (25, 2): return .zero
        case (25, 1): return CGPoint(x: 0, y: (bullR + outerBullR) / 2)
        default:
            let r: Double
            switch hit.multiplier {
            case 3: r = (trebleInR + trebleOutR) / 2
            case 2: r = (doubleInR + doubleOutR) / 2
            default: r = (outerBullR + trebleInR) / 2 + 10
            }
            let a = centerAngle(of: hit.segment) * .pi / 180
            return CGPoint(x: r * cos(a), y: r * sin(a))
        }
    }

    /// De 4 kalibratiepunten: buitenrand double-ring op de draad tussen 5|20, 13|6, 17|3, 8|11.
    /// Zelfde punten en volgorde als de DeepDarts-dataset, zodat een daarop getraind YOLO-model
    /// (klassen cal1…cal4) rechtstreeks de kalibratie kan leveren.
    static let calibrationAnglesDeg: [Double] = [99, 9, -81, -171]
    static let calibrationLabels = ["5 | 20", "13 | 6", "17 | 3", "8 | 11"]
    static var calibrationPointsMM: [CGPoint] {
        calibrationAnglesDeg.map { deg in
            let rad = deg * .pi / 180
            return CGPoint(x: doubleOutR * cos(rad), y: doubleOutR * sin(rad))
        }
    }
}

// MARK: - Homografie (projectieve transformatie tussen twee vlakken)

struct Homography: Equatable {
    /// 3×3 matrix, rij-voor-rij.
    let m: [Double]

    init(matrix: [Double]) {
        precondition(matrix.count == 9)
        m = matrix
    }

    /// Berekent H zodat H·src ≈ dst, uit exact 4 puntparen (geen 3 op één lijn).
    init?(from src: [CGPoint], to dst: [CGPoint]) {
        guard src.count == 4, dst.count == 4 else { return nil }
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = Double(src[i].x), y = Double(src[i].y)
            let u = Double(dst[i].x), v = Double(dst[i].y)
            a[2 * i]     = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        for c in 0..<8 {
            var pivot = c
            for r in (c + 1)..<8 where abs(a[r][c]) > abs(a[pivot][c]) { pivot = r }
            guard abs(a[pivot][c]) > 1e-10 else { return nil }
            a.swapAt(c, pivot)
            for r in 0..<8 where r != c {
                let f = a[r][c] / a[c][c]
                if f == 0 { continue }
                for k in c..<9 { a[r][k] -= f * a[c][k] }
            }
        }
        var h = (0..<8).map { a[$0][8] / a[$0][$0] }
        h.append(1)
        guard h.allSatisfy({ $0.isFinite }) else { return nil }
        m = h
    }

    /// Kleinste-kwadraten-homografie uit 4 of meer puntparen (genormaliseerd, Hartley).
    init?(leastSquaresFrom src: [CGPoint], to dst: [CGPoint]) {
        guard src.count == dst.count, src.count >= 4 else { return nil }
        if src.count == 4 { self.init(from: src, to: dst); return }

        func normalizer(_ pts: [CGPoint]) -> Homography {
            let n = Double(pts.count)
            let cx = pts.reduce(0) { $0 + Double($1.x) } / n
            let cy = pts.reduce(0) { $0 + Double($1.y) } / n
            let d = pts.reduce(0) { $0 + hypot(Double($1.x) - cx, Double($1.y) - cy) } / n
            let s = d > 0 ? 2.0.squareRoot() / d : 1
            return Homography(matrix: [s, 0, -s * cx, 0, s, -s * cy, 0, 0, 1])
        }
        let ts = normalizer(src), td = normalizer(dst)
        let ns = src.map(ts.apply), nd = dst.map(td.apply)

        // Normaalvergelijkingen AᵀA·h = Aᵀb met h33 = 1
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<ns.count {
            let x = Double(ns[i].x), y = Double(ns[i].y), u = Double(nd[i].x), v = Double(nd[i].y)
            for row in [[x, y, 1, 0, 0, 0, -u * x, -u * y, u], [0, 0, 0, x, y, 1, -v * x, -v * y, v]] {
                for r in 0..<8 {
                    for c in 0..<9 { ata[r][c] += row[r] * row[c] }
                }
            }
        }
        for c in 0..<8 {
            var pivot = c
            for r in (c + 1)..<8 where abs(ata[r][c]) > abs(ata[pivot][c]) { pivot = r }
            guard abs(ata[pivot][c]) > 1e-12 else { return nil }
            ata.swapAt(c, pivot)
            for r in 0..<8 where r != c {
                let f = ata[r][c] / ata[c][c]
                if f == 0 { continue }
                for k in c..<9 { ata[r][k] -= f * ata[c][k] }
            }
        }
        var h = (0..<8).map { ata[$0][8] / ata[$0][$0] }
        h.append(1)
        guard h.allSatisfy({ $0.isFinite }), let tdInv = td.inverse else { return nil }
        // H = Td⁻¹ · Hn · Ts
        let full = tdInv.multiplied(by: Homography(matrix: h)).multiplied(by: ts)
        let w = full.m[8]
        guard abs(w) > 1e-14 else { return nil }
        self.init(matrix: full.m.map { $0 / w })
    }

    /// self · other
    func multiplied(by o: Homography) -> Homography {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { r[i * 3 + j] += m[i * 3 + k] * o.m[k * 3 + j] } } }
        return Homography(matrix: r)
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w,
                       y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    var inverse: Homography? {
        let a = m
        let det = a[0] * (a[4] * a[8] - a[5] * a[7])
                - a[1] * (a[3] * a[8] - a[5] * a[6])
                + a[2] * (a[3] * a[7] - a[4] * a[6])
        guard abs(det) > 1e-14 else { return nil }
        let inv = [
            (a[4] * a[8] - a[5] * a[7]), -(a[1] * a[8] - a[2] * a[7]),  (a[1] * a[5] - a[2] * a[4]),
           -(a[3] * a[8] - a[5] * a[6]),  (a[0] * a[8] - a[2] * a[6]), -(a[0] * a[5] - a[2] * a[3]),
            (a[3] * a[7] - a[4] * a[6]), -(a[0] * a[7] - a[1] * a[6]),  (a[0] * a[4] - a[1] * a[3])
        ].map { $0 / det }
        return Homography(matrix: inv)
    }
}

/// Eenvoudige 2D-richting (platformonafhankelijk).
struct Vector2D: Equatable {
    var dx: Double
    var dy: Double
}

// MARK: - Kalibratie: alles wat de camera-pipeline over het bord weet

struct BoardCalibration: Equatable {
    /// Beeldcoördinaten zijn pixels van het volledige camerabeeld, oorsprong linksboven, y omlaag.
    let imageSize: CGSize
    let imagePoints: [CGPoint]
    /// beeld → mm
    let toBoard: Homography
    /// mm → beeld
    let toImage: Homography
    /// Uitsnede rond het bord (incl. marge voor pijlen in de rand), in beeldpixels.
    let roi: CGRect
    /// Richting in het beeld (eenheidsvector) waar de camera staat. De pijlpunt is het uiteinde
    /// van de pijl dat in deze richting ligt. nil = camera staat recht voor het bord.
    let cameraSideDirection: Vector2D?
    /// Hoe schuin de camera staat (1.0 = recht ervoor). Handig voor feedback in de UI.
    let obliqueness: Double

    init?(imagePoints: [CGPoint], imageSize: CGSize) {
        guard imagePoints.count == 4,
              let toBoard = Homography(from: imagePoints, to: BoardGeometry.calibrationPointsMM),
              let toImage = toBoard.inverse else { return nil }
        self.imageSize = imageSize
        self.imagePoints = imagePoints
        self.toBoard = toBoard
        self.toImage = toImage

        // Uitsnede: cirkel met 125% van de double-ring, begrensd door het beeld.
        let outline = stride(from: 0.0, to: 360.0, by: 10.0).map { deg -> CGPoint in
            let r = BoardGeometry.doubleOutR * 1.25, a = deg * .pi / 180
            return toImage.apply(CGPoint(x: r * cos(a), y: r * sin(a)))
        }
        let xs = outline.map { Double($0.x) }, ys = outline.map { Double($0.y) }
        let frame = CGRect(origin: .zero, size: imageSize)
        let raw = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let clipped = raw.intersection(frame)
        guard !clipped.isNull, clipped.width > 50, clipped.height > 50 else { return nil }
        roi = clipped.integral

        // Camerarichting: de kant van het bord die dichter bij de camera is, verschijnt groter.
        let c = toImage.apply(.zero)
        func radius(_ deg: Double) -> Double {
            let a = deg * .pi / 180
            let p = toImage.apply(CGPoint(x: 170 * cos(a), y: 170 * sin(a)))
            return hypot(Double(p.x - c.x), Double(p.y - c.y))
        }
        var bestDeg = 0.0, bestRatio = 0.0
        for deg in stride(from: 0.0, to: 360.0, by: 5.0) {
            let ratio = radius(deg) / max(radius(deg + 180), 0.0001)
            if ratio > bestRatio { bestRatio = ratio; bestDeg = deg }
        }
        obliqueness = bestRatio
        if bestRatio < 1.03 {
            cameraSideDirection = nil
        } else {
            let a = bestDeg * .pi / 180
            let p = toImage.apply(CGPoint(x: 170 * cos(a), y: 170 * sin(a)))
            let dx = Double(p.x - c.x), dy = Double(p.y - c.y), len = hypot(dx, dy)
            cameraSideDirection = Vector2D(dx: dx / len, dy: dy / len)
        }
    }
}
