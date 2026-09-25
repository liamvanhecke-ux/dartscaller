import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Eén opgeslagen camerabeeld (bord-uitsnede) van tijdens het spel, voor het hertrainen van het model.
struct TrainingSample: Codable, Identifiable, Equatable {
    var id = UUID()
    var createdAt = Date()
    /// Grootte van de opgeslagen uitsnede (pixels).
    var width: Int
    var height: Int
    /// Uitsnede in het volledige camerabeeld (pixels, linksboven).
    var roi: [Double]                 // x, y, w, h
    /// Homografie mm → volledig camerabeeld (9 waarden, rij-voor-rij).
    var boardToImage: [Double]
    /// De fysieke pijlen die op dat moment in het bord zaten.
    var dartIDs: [UUID]

    var imageFileName: String { "\(id.uuidString).jpg" }
}

/// Eindlabel van één fysieke pijl.
enum DartLabel: Codable, Equatable {
    /// Positie (mm). `approximate`: afgeleid uit een correctie (in het juiste vak, niet op de mm exact).
    case point(x: Double, y: Double, approximate: Bool)
    /// Geen echte pijl (valse detectie, ongedaan gemaakt) → niet labelen.
    case notADart
}

enum TrainingLabelMaker {

    /// Klassen in dezelfde volgorde als het meegeleverde model (Training/darts.yaml).
    static let classNames = ["20", "3", "11", "6", "dart", "9", "15"]
    static let dartClass = 4
    /// Klasse → hoek van het kalibratiepunt op de buitenrand van de double-ring.
    static let calibrationAngles: [Int: Double] = [0: 99, 1: -81, 2: -171, 3: 9, 5: 153, 6: -27]

    /// YOLO-labelregels voor een voorbeeld, of nil als het niet volledig gelabeld is
    /// (een pijl zonder eindlabel → onbetrouwbaar, niet gebruiken).
    static func yoloLines(for sample: TrainingSample, labels: [UUID: DartLabel], box: Double = 0.025) -> [String]? {
        guard sample.roi.count == 4, sample.boardToImage.count == 9, sample.width > 0, sample.height > 0 else { return nil }
        let toImage = Homography(matrix: sample.boardToImage)
        let rx = sample.roi[0], ry = sample.roi[1], rw = sample.roi[2], rh = sample.roi[3]

        func normalized(_ mm: CGPoint) -> (Double, Double)? {
            let p = toImage.apply(mm)
            let nx = (Double(p.x) - rx) / rw, ny = (Double(p.y) - ry) / rh
            return (0...1).contains(nx) && (0...1).contains(ny) ? (nx, ny) : nil
        }
        func line(_ cls: Int, _ p: (Double, Double)) -> String {
            String(format: "%d %.6f %.6f %.6f %.6f", cls, p.0, p.1, box, box)
        }

        var lines: [String] = []
        for cls in calibrationAngles.keys.sorted() {
            let a = calibrationAngles[cls]! * .pi / 180
            let mm = CGPoint(x: BoardGeometry.doubleOutR * cos(a), y: BoardGeometry.doubleOutR * sin(a))
            if let p = normalized(mm) { lines.append(line(cls, p)) }
        }
        for id in sample.dartIDs {
            switch labels[id] {
            case .none:
                return nil
            case .notADart:
                continue
            case .point(let x, let y, _):
                if let p = normalized(CGPoint(x: x, y: y)) { lines.append(line(dartClass, p)) }
            }
        }
        return lines
    }

    static var datasetYAML: String {
        var s = "# Gemaakt door DartsCaller tijdens het spelen. Train met: python train.py (map Training/)\n"
        s += "train: images/train\nval: images/train\nnames:\n"   // geen 'path': Ultralytics gebruikt dan de map van dit bestand
        for (i, n) in classNames.enumerated() { s += "  \(i): '\(n)'\n" }
        return s
    }
}
