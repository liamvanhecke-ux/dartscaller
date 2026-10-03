import Foundation

/// Herkent en compenseert "globale" beweging: het HELE beeld verschuift tegelijk (statief trilt
/// omdat iemand het scherm aanraakt). Een pijl beweegt lokaal; een trillend statief beweegt alles.
///
/// Methode: rij- en kolomprofielen (gemiddelde helderheid per rij/kolom) vergelijken.
/// Een verschuiving van het hele beeld schuift die profielen mee; een pijl verandert ze nauwelijks.
/// Zeer goedkoop (lineair in het aantal pixels), dus geschikt voor elk frame op 60 fps.
enum GlobalMotion {

    struct Shift: Equatable {
        var dx: Int
        var dy: Int
        static let zero = Shift(dx: 0, dy: 0)
        var isZero: Bool { dx == 0 && dy == 0 }
        static func + (a: Shift, b: Shift) -> Shift { Shift(dx: a.dx + b.dx, dy: a.dy + b.dy) }
        static prefix func - (a: Shift) -> Shift { Shift(dx: -a.dx, dy: -a.dy) }
    }

    /// Hoeveel `b` verschoven is t.o.v. `a`:  b(x, y) ≈ a(x − dx, y − dy).
    /// - Parameter minImprovement: een verschuiving wordt pas aangenomen als ze de fout minstens
    ///   met deze factor verkleint t.o.v. "geen verschuiving" (voorkomt valse verschuivingen door een pijl).
    /// - Parameter minStructure: minimale spreiding (grijswaarden) van een profiel. Egale beelden
    ///   hebben geen structuur om een verschuiving aan te meten → dan geen trilling aannemen.
    static func estimateShift(from a: GrayImage, to b: GrayImage, maxShift: Int,
                              minImprovement: Double = 0.8, minStructure: Double = 2.0) -> Shift {
        guard a.width == b.width, a.height == b.height, maxShift > 0,
              a.width > 2 * maxShift + 4, a.height > 2 * maxShift + 4 else { return .zero }
        let colA = columnMeans(a), rowA = rowMeans(a)
        let dx = std(colA) >= minStructure
            ? bestShift(colA, columnMeans(b), maxShift: maxShift, minImprovement: minImprovement) : 0
        let dy = std(rowA) >= minStructure
            ? bestShift(rowA, rowMeans(b), maxShift: maxShift, minImprovement: minImprovement) : 0
        return Shift(dx: dx, dy: dy)
    }

    private static func std(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let m = v.reduce(0, +) / Double(v.count)
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)).squareRoot()
    }

    /// Aantal veranderde pixels NA compensatie van de verschuiving (randen worden overgeslagen).
    static func changedPixelCount(_ a: GrayImage, _ b: GrayImage, shift s: Shift, threshold: Int) -> Int {
        guard a.width == b.width, a.height == b.height else { return Int.max }
        let m = max(abs(s.dx), abs(s.dy))
        guard a.width > 2 * m, a.height > 2 * m else { return 0 }
        var n = 0
        for y in m..<(b.height - m) {
            let ya = y - s.dy
            for x in m..<(b.width - m) {
                let d = Int(b.pixels[y * b.width + x]) - Int(a.pixels[ya * a.width + (x - s.dx)])
                if abs(d) > threshold { n += 1 }
            }
        }
        return n
    }

    /// Verschuift een beeld: out(x, y) = img(x − dx, y − dy). Randen worden aangevuld met de randpixel.
    static func shifted(_ img: GrayImage, by s: Shift) -> GrayImage {
        guard !s.isZero else { return img }
        var out = img
        for y in 0..<img.height {
            let sy = min(max(y - s.dy, 0), img.height - 1)
            for x in 0..<img.width {
                let sx = min(max(x - s.dx, 0), img.width - 1)
                out.pixels[y * img.width + x] = img.pixels[sy * img.width + sx]
            }
        }
        return out
    }

    // MARK: Sub-pixel (voor de baseline-uitlijning)

    /// Zelfde als `estimateShift`, maar op ±0,1 px nauwkeurig (parabool door de foutcurve).
    /// Nodig omdat een statief dat 0,5 px zakt op scherpe draden al overal "verandering" geeft.
    static func estimateSubpixelShift(from a: GrayImage, to b: GrayImage, maxShift: Int,
                                      minStructure: Double = 2.0) -> Vector2D {
        guard a.width == b.width, a.height == b.height, maxShift > 0,
              a.width > 2 * maxShift + 4, a.height > 2 * maxShift + 4 else { return Vector2D(dx: 0, dy: 0) }
        let colA = columnMeans(a), rowA = rowMeans(a)
        let dx = std(colA) >= minStructure ? subpixelShift(colA, columnMeans(b), maxShift: maxShift) : 0
        let dy = std(rowA) >= minStructure ? subpixelShift(rowA, rowMeans(b), maxShift: maxShift) : 0
        return Vector2D(dx: dx, dy: dy)
    }

    /// Verschuift met bilineaire interpolatie: out(x, y) = img(x − dx, y − dy).
    static func shifted(_ img: GrayImage, by v: Vector2D) -> GrayImage {
        guard abs(v.dx) > 1e-6 || abs(v.dy) > 1e-6 else { return img }
        var out = img
        let w = img.width, h = img.height
        for y in 0..<h {
            let sy = min(max(Double(y) - v.dy, 0), Double(h - 1))
            let y0 = Int(sy), y1 = min(y0 + 1, h - 1), fy = sy - Double(y0)
            for x in 0..<w {
                let sx = min(max(Double(x) - v.dx, 0), Double(w - 1))
                let x0 = Int(sx), x1 = min(x0 + 1, w - 1), fx = sx - Double(x0)
                let p00 = Double(img.pixels[y0 * w + x0]), p10 = Double(img.pixels[y0 * w + x1])
                let p01 = Double(img.pixels[y1 * w + x0]), p11 = Double(img.pixels[y1 * w + x1])
                let v = (p00 * (1 - fx) + p10 * fx) * (1 - fy) + (p01 * (1 - fx) + p11 * fx) * fy
                out.pixels[y * w + x] = UInt8(min(255, max(0, v.rounded())))
            }
        }
        return out
    }

    private static func subpixelShift(_ p: [Double], _ q: [Double], maxShift: Int) -> Double {
        func err(_ s: Int) -> Double {
            var e = 0.0, n = 0
            for i in (maxShift + 1)..<(p.count - maxShift - 1) { e += abs(q[i] - p[i - s]); n += 1 }
            return n > 0 ? e / Double(n) : .infinity
        }
        var best = 0, bestErr = err(0)
        for s in 1...maxShift {
            for c in [s, -s] { let e = err(c); if e < bestErr { best = c; bestErr = e } }
        }
        guard best > -maxShift, best < maxShift else { return Double(best) }
        let em = err(best - 1), ep = err(best + 1)
        let denom = em - 2 * bestErr + ep
        guard denom > 1e-9 else { return Double(best) }
        return Double(best) + max(-0.5, min(0.5, 0.5 * (em - ep) / denom))
    }

    // MARK: Intern

    private static func columnMeans(_ img: GrayImage) -> [Double] {
        var c = [Double](repeating: 0, count: img.width)
        for y in 0..<img.height {
            let row = y * img.width
            for x in 0..<img.width { c[x] += Double(img.pixels[row + x]) }
        }
        return c.map { $0 / Double(img.height) }
    }

    private static func rowMeans(_ img: GrayImage) -> [Double] {
        (0..<img.height).map { y in
            var s = 0.0
            let row = y * img.width
            for x in 0..<img.width { s += Double(img.pixels[row + x]) }
            return s / Double(img.width)
        }
    }

    /// Zoekt s zodat q[i] ≈ p[i − s]. Kleine verschuivingen eerst; 0 wint bij twijfel.
    private static func bestShift(_ p: [Double], _ q: [Double], maxShift: Int, minImprovement: Double) -> Int {
        func err(_ s: Int) -> Double {
            var e = 0.0, n = 0
            for i in maxShift..<(p.count - maxShift) { e += abs(q[i] - p[i - s]); n += 1 }
            return n > 0 ? e / Double(n) : .infinity
        }
        let e0 = err(0)
        var best = 0, bestErr = e0
        for s in 1...maxShift {
            for cand in [s, -s] {
                let e = err(cand)
                if e < bestErr { best = cand; bestErr = e }
            }
        }
        return best != 0 && bestErr < e0 * minImprovement ? best : 0
    }
}
