import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Grijswaardenbeeld. Rij 0 = bovenkant (zelfde oriëntatie als het camerabeeld op het scherm).
struct GrayImage: Equatable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(width: Int, height: Int, fill: UInt8 = 0) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Van RGBA (rij 0 = boven) naar grijs.
    init(rgba: [UInt8], width: Int, height: Int) {
        var g = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Int(rgba[4 * i]), gg = Int(rgba[4 * i + 1]), b = Int(rgba[4 * i + 2])
            g[i] = UInt8((r * 77 + gg * 150 + b * 29) >> 8)
        }
        self.init(width: width, height: height, pixels: g)
    }
}

struct RGBAImage {
    let width: Int
    let height: Int
    /// RGBA, 8 bit per kanaal, rij 0 = boven.
    let pixels: [UInt8]
}

struct Blob {
    var xs: [Int] = []
    var ys: [Int] = []
    var area: Int { xs.count }
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min

    mutating func add(_ x: Int, _ y: Int) {
        xs.append(x); ys.append(y)
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }

    mutating func merge(_ o: Blob) {
        for i in 0..<o.area { add(o.xs[i], o.ys[i]) }
    }

    var boundingBox: CGRect {
        CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

enum ChangeKind: Equatable {
    /// Niets relevants veranderd (ruis, licht).
    case none
    /// Er is iets bijgekomen dat op een pijl lijkt.
    case dartAdded
    /// Pijlen zijn uit het bord gehaald (beeld lijkt meer op het lege bord).
    case dartsRemoved
    /// Groot deel van het bord veranderd: hand, persoon, of camera verschoven.
    case obstruction
}

struct ChangeAnalysis {
    let kind: ChangeKind
    /// Samengevoegde blob van de nieuwe pijl (alleen bij .dartAdded).
    let dartBlob: Blob?
    let changedFraction: Double
}

enum ImageAnalysis {

    // MARK: Beweging

    /// Gemiddeld absoluut verschil, 0...1.
    static func meanAbsDifference(_ a: GrayImage, _ b: GrayImage) -> Double {
        guard a.width == b.width, a.height == b.height, !a.pixels.isEmpty else { return 1 }
        var sum = 0
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for i in 0..<pa.count { sum += abs(Int(pa[i]) - Int(pb[i])) }
            }
        }
        return Double(sum) / Double(a.pixels.count) / 255
    }

    /// Aantal pixels dat meer dan `threshold` grijswaarden verschilt. Gevoeliger dan een gemiddelde:
    /// een pijl beslaat maar een paar pixels van het bord.
    static func changedPixelCount(_ a: GrayImage, _ b: GrayImage, threshold: Int) -> Int {
        guard a.width == b.width, a.height == b.height else { return Int.max }
        var n = 0
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for i in 0..<pa.count where abs(Int(pa[i]) - Int(pb[i])) > threshold { n += 1 }
            }
        }
        return n
    }

    // MARK: Verschil-analyse na "Motion Settlement"

    struct ChangeParameters {
        /// Minimaal grijsverschil om een pixel als veranderd te zien.
        var pixelThreshold: Int = 28
        /// Kleinste blob (pixels) die als pijl mag tellen.
        var minDartArea: Int = 60
        /// Groter dan dit deel van het beeld = obstructie.
        var obstructionFraction: Double = 0.12
        /// Hoeveel dichter bij het lege bord (grijswaarde) = pijlen verwijderd.
        var removalMargin: Double = 8
    }

    static func analyzeChange(current: GrayImage, reference: GrayImage, emptyBoard: GrayImage?,
                              params: ChangeParameters = .init()) -> ChangeAnalysis {
        precondition(current.width == reference.width && current.height == reference.height)
        let w = current.width, h = current.height
        var mask = [Bool](repeating: false, count: w * h)
        var changed = 0
        for i in 0..<(w * h) where abs(Int(current.pixels[i]) - Int(reference.pixels[i])) > params.pixelThreshold {
            mask[i] = true
            changed += 1
        }
        let fraction = Double(changed) / Double(w * h)
        if fraction > params.obstructionFraction {
            return ChangeAnalysis(kind: .obstruction, dartBlob: nil, changedFraction: fraction)
        }
        guard changed >= params.minDartArea / 2 else {
            return ChangeAnalysis(kind: .none, dartBlob: nil, changedFraction: fraction)
        }

        // Losse ruispixels weg: minstens 2 veranderde buren (8-buurt) nodig.
        var clean = [Bool](repeating: false, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where mask[y * w + x] {
                var n = 0
                for dy in -1...1 { for dx in -1...1 where !(dx == 0 && dy == 0) && mask[(y + dy) * w + x + dx] { n += 1 } }
                if n >= 2 { clean[y * w + x] = true }
            }
        }

        // Pijlen verwijderd? Op de veranderde pixels: lijkt het huidige beeld meer op het lege bord?
        if let empty = emptyBoard, empty.width == w, empty.height == h {
            var closer = 0.0, count = 0
            for i in 0..<(w * h) where clean[i] {
                let refDist = abs(Int(reference.pixels[i]) - Int(empty.pixels[i]))
                let curDist = abs(Int(current.pixels[i]) - Int(empty.pixels[i]))
                closer += Double(refDist - curDist)
                count += 1
            }
            if count > 0 && closer / Double(count) > params.removalMargin {
                return ChangeAnalysis(kind: .dartsRemoved, dartBlob: nil, changedFraction: fraction)
            }
        }

        var blobs = components(clean, width: w, height: h, minArea: max(4, params.minDartArea / 6))
        guard !blobs.isEmpty else { return ChangeAnalysis(kind: .none, dartBlob: nil, changedFraction: fraction) }
        blobs.sort { $0.area > $1.area }

        // Een pijl valt in het verschilbeeld vaak in stukken uiteen (dunne schacht). Voeg nabije stukken samen.
        var dart = blobs[0]
        let box = dart.boundingBox
        let grow = max(10, max(box.width, box.height) * 0.35)
        let zone = box.insetBy(dx: -grow, dy: -grow)
        for b in blobs.dropFirst() where zone.intersects(b.boundingBox) { dart.merge(b) }

        guard dart.area >= params.minDartArea else {
            return ChangeAnalysis(kind: .none, dartBlob: nil, changedFraction: fraction)
        }
        return ChangeAnalysis(kind: .dartAdded, dartBlob: dart, changedFraction: fraction)
    }

    /// 8-verbonden componenten.
    static func components(_ mask: [Bool], width w: Int, height h: Int, minArea: Int) -> [Blob] {
        var visited = [Bool](repeating: false, count: w * h)
        var result: [Blob] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where mask[start] && !visited[start] {
            var blob = Blob()
            visited[start] = true
            stack.append(start)
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                blob.add(x, y)
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0 && ny < h else { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0 && nx < w else { continue }
                        let j = ny * w + nx
                        if mask[j] && !visited[j] { visited[j] = true; stack.append(j) }
                    }
                }
            }
            if blob.area >= minArea { result.append(blob) }
        }
        return result
    }

    // MARK: Verificatie van een kandidaat-pijl

    /// Verhouding lange/korte as (PCA). Pijl ≈ 3–10, schaduw/vlek ≈ 1–2.
    static func elongation(of blob: Blob) -> Double {
        guard blob.area >= 3 else { return 1 }
        let n = Double(blob.area)
        var mx = 0.0, my = 0.0
        for i in 0..<blob.area { mx += Double(blob.xs[i]); my += Double(blob.ys[i]) }
        mx /= n; my /= n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in 0..<blob.area {
            let dx = Double(blob.xs[i]) - mx, dy = Double(blob.ys[i]) - my
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let tr = sxx + syy, det = sxx * syy - sxy * sxy
        let disc = max(0, tr * tr / 4 - det).squareRoot()
        let l1 = tr / 2 + disc, l2 = max(tr / 2 - disc, 1e-6)
        return (l1 / l2).squareRoot()
    }

    /// Gemiddeld grijsverschil binnen de blob (schaduwen zijn zacht, pijlen scherp).
    static func contrast(of blob: Blob, _ a: GrayImage, _ b: GrayImage) -> Double {
        guard blob.area > 0 else { return 0 }
        var sum = 0
        for i in 0..<blob.area {
            let idx = blob.ys[i] * a.width + blob.xs[i]
            sum += abs(Int(a.pixels[idx]) - Int(b.pixels[idx]))
        }
        return Double(sum) / Double(blob.area)
    }

    static func meanBrightness(_ img: GrayImage) -> Double {
        guard !img.pixels.isEmpty else { return 0 }
        return Double(img.pixels.reduce(0) { $0 + Int($1) }) / Double(img.pixels.count)
    }

    // MARK: Pijlpunt

    /// De punt is het uiteinde van de pijl aan de kant van de camera (zie BoardCalibration.cameraSideDirection).
    /// Geeft coördinaten in het grijsbeeld (pixelcentrum).
    static func locateTip(of blob: Blob, cameraSide: Vector2D?) -> CGPoint {
        let n = Double(blob.area)
        var mx = 0.0, my = 0.0
        for i in 0..<blob.area { mx += Double(blob.xs[i]); my += Double(blob.ys[i]) }
        mx /= n; my /= n

        guard let side = cameraSide else {
            // Camera recht voor het bord: beste gok is het zwaartepunt.
            return CGPoint(x: mx + 0.5, y: my + 0.5)
        }

        // Hoofdas via PCA.
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in 0..<blob.area {
            let dx = Double(blob.xs[i]) - mx, dy = Double(blob.ys[i]) - my
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let tr = sxx + syy, det = sxx * syy - sxy * sxy
        let disc = max(0, tr * tr / 4 - det).squareRoot()
        let l1 = tr / 2 + disc, l2 = max(tr / 2 - disc, 1e-9)
        var ax: Double, ay: Double
        if abs(sxy) > 1e-9 { ax = l1 - syy; ay = sxy } else if sxx >= syy { ax = 1; ay = 0 } else { ax = 0; ay = 1 }
        let len = hypot(ax, ay); ax /= len; ay /= len

        let sx = Double(side.dx), sy = Double(side.dy)
        let dirX: Double, dirY: Double
        if l1 / l2 > 3 {
            // Langwerpig: volg de pijlas, richting de camerakant.
            let s = (ax * sx + ay * sy) >= 0 ? 1.0 : -1.0
            dirX = ax * s; dirY = ay * s
        } else {
            // Rond (bv. flight van voren): gebruik de camerarichting zelf.
            dirX = sx; dirY = sy
        }

        var maxProj = -Double.infinity
        for i in 0..<blob.area {
            let p = Double(blob.xs[i]) * dirX + Double(blob.ys[i]) * dirY
            if p > maxProj { maxProj = p }
        }
        // Gemiddelde van het uiterste "kapje" = stabieler dan één pixel.
        var tx = 0.0, ty = 0.0, k = 0.0
        for i in 0..<blob.area {
            let p = Double(blob.xs[i]) * dirX + Double(blob.ys[i]) * dirY
            if p >= maxProj - 2.0 { tx += Double(blob.xs[i]); ty += Double(blob.ys[i]); k += 1 }
        }
        return CGPoint(x: tx / k + 0.5, y: ty / k + 0.5)
    }

    // MARK: Bord zoeken (voor auto-zoom)

    /// Zoekt de rood/groene ringen van het dartbord. Geeft de bounding box van de double-ring
    /// (in pixels van `image`), of nil als er geen bord gevonden is.
    static func detectBoard(in image: RGBAImage) -> CGRect? {
        let w = image.width, h = image.height
        guard w > 8, h > 8 else { return nil }
        var mask = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let r = Double(image.pixels[4 * i]) / 255
            let g = Double(image.pixels[4 * i + 1]) / 255
            let b = Double(image.pixels[4 * i + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            guard mx > 0.22, d / max(mx, 0.0001) > 0.45 else { continue }
            var hue: Double
            if mx == r { hue = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { hue = 60 * ((b - r) / d + 2) }
            else { hue = 60 * ((r - g) / d + 4) }
            if hue < 0 { hue += 360 }
            let isRed = hue < 18 || hue > 335
            let isGreen = hue > 85 && hue < 170
            mask[i] = isRed || isGreen
        }
        // 1 pixel dilatatie: dunne spider-draden tussen rood en groen overbruggen.
        var dilated = mask
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where mask[y * w + x] {
                for dy in -1...1 { for dx in -1...1 { dilated[(y + dy) * w + x + dx] = true } }
            }
        }
        let blobs = components(dilated, width: w, height: h, minArea: max(20, w * h / 400))
        guard let ring = blobs.max(by: { $0.area < $1.area }) else { return nil }
        let box = ring.boundingBox
        let aspect = box.width / max(box.height, 1)
        guard aspect > 0.4, aspect < 2.5, box.width > CGFloat(w) * 0.08 else { return nil }
        // De ring moet hol zijn: het midden van de box hoort niet vol rood/groen te zitten.
        let fill = Double(ring.area) / Double(box.width * box.height)
        guard fill < 0.6 else { return nil }
        return box
    }

    /// Beginposities voor de 4 kalibratiepunten, geschat uit de bord-box (bord rechtop verondersteld).
    static func initialCalibrationGuess(boardBox b: CGRect) -> [CGPoint] {
        BoardGeometry.calibrationAnglesDeg.map { deg in
            let a = deg * .pi / 180
            return CGPoint(x: Double(b.midX) + Double(b.width) / 2 * cos(a),
                           y: Double(b.midY) - Double(b.height) / 2 * sin(a))   // beeld: y omlaag
        }
    }
}
