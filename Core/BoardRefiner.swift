import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(simd)
import simd
#endif

/// Verfijnt een ruwe kalibratie (YOLO-punten, kleurdetectie of aangetikte punten) tot een
/// nauwkeurige perspectiefmatrix.
///
/// Waarom geen Hough Circles? Door het schuine camerastandpunt is het bord een ELLIPS, geen cirkel.
/// Deze aanpak werkt met elk perspectief:
///   1. Met de ruwe kalibratie weten we ongeveer waar elke hoek van het bord in beeld ligt.
///   2. Langs ±60 stralen zoeken we de exacte BUITENRAND van de double-ring (rood/groen → zwart).
///   3. Het middelpunt van de bull (rood + groen vlekje) is een extra ankerpunt.
///   4. Homografie met kleinste kwadraten over al die punten, uitschieters eruit, opnieuw fitten.
/// Resultaat: 60+ meetpunten i.p.v. 4 → veel minder gevoelig voor één slecht aangetikt punt.
enum BoardRefiner {

    struct Result {
        /// De 4 standaard kalibratiepunten (beeldpixels, volle resolutie), verfijnd.
        let points: [CGPoint]
        /// mm → beeld
        let boardToImage: Homography
        /// Aantal gebruikte randpunten (na uitschieters).
        let edgePoints: Int
        /// Gemiddelde fout (beeldpixels) van de randpunten t.o.v. de fit.
        let rmsErrorPx: Double
        /// Afstand (mm) tussen gedetecteerde bull en het middelpunt volgens de kalibratie. nil = bull niet gevonden.
        let bullOffsetMM: Double?
    }

    struct Parameters {
        var minSaturation = 0.33
        var minValue = 0.16
        /// Minimum aantal randpunten voor een betrouwbare fit.
        var minEdgePoints = 16
        /// Stralen per vak (rond het midden van elk vak, weg van de draden).
        var raysPerSegment: [Double] = [-4.5, 0, 4.5]
    }

    /// - Parameters:
    ///   - image: RGBA-beeld (mag verkleind zijn t.o.v. `imageSize`), rij 0 = boven.
    ///   - rough: 4 ruwe kalibratiepunten in volle-resolutie beeldpixels.
    ///   - imageSize: volle beeldgrootte.
    static func refine(image: RGBAImage, rough: [CGPoint], imageSize: CGSize,
                       params: Parameters = .init()) -> Result? {
        guard let roughCal = BoardCalibration(imagePoints: rough, imageSize: imageSize) else { return nil }
        let s = Double(image.width) / Double(imageSize.width)          // volle res → beeld

        func ringColor(_ full: CGPoint) -> RingColor?? {
            let x = Int((Double(full.x) * s).rounded(.down)), y = Int((Double(full.y) * s).rounded(.down))
            guard x >= 0, y >= 0, x < image.width, y < image.height else { return .none }   // buiten beeld
            return .some(ringColorAt(image, x, y, params))
        }

        // Iteratief: elke ronde meten met de vorige (betere) schatting.
        var H = roughCal.toImage
        var lastBoard: [CGPoint] = [], lastImage: [CGPoint] = [], edgeCount = 0
        for _ in 0..<4 {
            var board: [CGPoint] = [], img: [CGPoint] = []
            func polar(_ r: Double, _ deg: Double) -> CGPoint {
                CGPoint(x: r * cos(deg * .pi / 180), y: r * sin(deg * .pi / 180))
            }

            // (a) Buitenrand double-ring langs stralen (bepaalt grootte/perspectief)
            var edges = 0
            for k in 0..<20 {
                for off in params.raysPerSegment {
                    let deg = 90.0 - Double(k) * 18 + off
                    var lastColored: Double?, outsideRun = 0, r = 150.0
                    while r <= 196 {
                        guard let c = ringColor(H.apply(polar(r, deg))) else { break }
                        if c != nil { lastColored = r; outsideRun = 0 }
                        else if lastColored != nil { outsideRun += 1; if outsideRun >= 4 { break } }
                        r += 0.5
                    }
                    guard let e = lastColored, e > 156, e < 188 else { continue }
                    board.append(polar(BoardGeometry.doubleOutR, deg))
                    img.append(H.apply(polar(e + 0.25, deg)))
                    edges += 1
                }
            }

            // (b) Vakgrenzen: overgang rood↔groen op double- en treble-ring (bepaalt de draaiing)
            for k in 0..<20 {
                let b0 = 99.0 - Double(k) * 18                          // ware grens tussen twee vakken
                for r in [(BoardGeometry.doubleInR + BoardGeometry.doubleOutR) / 2,
                          (BoardGeometry.trebleInR + BoardGeometry.trebleOutR) / 2] {
                    var samples: [(Double, RingColor)] = []
                    var d = -7.0
                    while d <= 7.0 {
                        if let c = ringColor(H.apply(polar(r, b0 + d))), let cc = c { samples.append((d, cc)) }
                        d += 0.1
                    }
                    // Dichtste overgang bij de verwachte grens
                    var best: Double?
                    for i in 1..<max(1, samples.count) where samples[i].1 != samples[i - 1].1 {
                        let mid = (samples[i].0 + samples[i - 1].0) / 2
                        if best == nil || abs(mid) < abs(best!) { best = mid }
                    }
                    guard let found = best, abs(found) < 6.5 else { continue }
                    // Gewicht 3: deze punten bepalen de draaiing; randpunten kunnen dat niet.
                    for _ in 0..<3 {
                        board.append(polar(r, b0))
                        img.append(H.apply(polar(r, b0 + found)))
                    }
                }
            }

            // (c) Bull: zwaartepunt van rood+groen binnen ±19 mm
            let c = H.apply(.zero)
            let rPx = [polar(20, 0), polar(20, 90), polar(20, 180), polar(20, 270)]
                .map { q -> Double in let p = H.apply(q); return hypot(Double(p.x - c.x), Double(p.y - c.y)) }
                .max()! * s
            if let inv = H.inverse {
                var sx = 0.0, sy = 0.0, n = 0.0
                let cx = Int(Double(c.x) * s), cy = Int(Double(c.y) * s), R = Int(rPx) + 2
                for y in max(0, cy - R)...max(0, min(image.height - 1, cy + R)) {
                    for x in max(0, cx - R)...max(0, min(image.width - 1, cx + R)) {
                        let full = CGPoint(x: (Double(x) + 0.5) / s, y: (Double(y) + 0.5) / s)
                        let mm = inv.apply(full)
                        guard hypot(Double(mm.x), Double(mm.y)) < 19, ringColorAt(image, x, y, params) != nil else { continue }
                        sx += Double(full.x); sy += Double(full.y); n += 1
                    }
                }
                if n >= 6 {
                    for _ in 0..<4 { board.append(.zero); img.append(CGPoint(x: sx / n, y: sy / n)) }   // gewicht 4
                }
            }

            guard edges >= params.minEdgePoints, board.count >= params.minEdgePoints,
                  var fit = Homography(leastSquaresFrom: board, to: img) else { return nil }
            // Uitschieters (pijl over de rand, vuil) eruit en opnieuw fitten
            var b = board, im = img
            for _ in 0..<2 {
                let res = zip(b, im).map { hypot(Double(fit.apply($0).x - $1.x), Double(fit.apply($0).y - $1.y)) }
                let med = res.sorted()[res.count / 2]
                let keep = res.indices.filter { res[$0] <= max(3.0, 3 * med) }
                guard keep.count >= params.minEdgePoints else { break }
                b = keep.map { b[$0] }; im = keep.map { im[$0] }
                guard let f2 = Homography(leastSquaresFrom: b, to: im) else { break }
                fit = f2
            }
            H = fit
            lastBoard = b; lastImage = im; edgeCount = b.count
        }

        let res = zip(lastBoard, lastImage).map { hypot(Double(H.apply($0).x - $1.x), Double(H.apply($0).y - $1.y)) }
        let rms = (res.reduce(0) { $0 + $1 * $1 } / Double(max(1, res.count))).squareRoot()
        var bullOffset: Double?
        if let i = lastBoard.firstIndex(of: .zero), let inv = H.inverse {
            let mm = inv.apply(lastImage[i])
            bullOffset = hypot(Double(mm.x), Double(mm.y))
        }
        return Result(points: BoardGeometry.calibrationPointsMM.map(H.apply), boardToImage: H,
                      edgePoints: edgeCount, rmsErrorPx: rms, bullOffsetMM: bullOffset)
    }

    enum RingColor { case red, green }

    /// Rood of groen (ringen/bull), anders nil.
    static func ringColorAt(_ img: RGBAImage, _ x: Int, _ y: Int, _ p: Parameters = .init()) -> RingColor? {
        let i = 4 * (y * img.width + x)
        let r = Double(img.pixels[i]) / 255, g = Double(img.pixels[i + 1]) / 255, b = Double(img.pixels[i + 2]) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard mx > p.minValue, d / max(mx, 1e-6) > p.minSaturation else { return nil }
        var h: Double
        if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = 60 * ((b - r) / d + 2) }
        else { h = 60 * ((r - g) / d + 4) }
        if h < 0 { h += 360 }
        if h < 20 || h > 330 { return .red }
        if h > 80 && h < 170 { return .green }
        return nil
    }

    /// Rood of groen van de double/treble-ring of bull.
    static func isRingColor(_ img: RGBAImage, _ x: Int, _ y: Int, _ p: Parameters = .init()) -> Bool {
        ringColorAt(img, x, y, p) != nil
    }
}

#if canImport(simd)
extension Homography {
    /// Zelfde matrix als `simd_float3x3` (kolom-hoofdvolgorde), bv. voor Core Image/Metal/Accelerate.
    /// Toepassen: let p = matrix * SIMD3<Float>(x, y, 1);  punt = (p.x / p.z, p.y / p.z)
    var simdMatrix: simd_float3x3 {
        let f = m.map(Float.init)
        return simd_float3x3(columns: (SIMD3(f[0], f[3], f[6]), SIMD3(f[1], f[4], f[7]), SIMD3(f[2], f[5], f[8])))
    }
}
#endif
