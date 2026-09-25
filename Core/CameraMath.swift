import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum CameraMath {
    /// Verhouding volledig bord (451 mm incl. nummerring) t.o.v. de double-ring (340 mm).
    static let boardToDoubleRing: CGFloat = 1.33

    /// Hoeveel extra digitale zoom nodig is zodat het hele bord het beeld vult,
    /// zonder dat het (bij een bord uit het midden) buiten beeld valt. 1 = niet zoomen.
    static func zoomFactor(forBoardBox box: CGRect, imageSize size: CGSize, fill: CGFloat = 0.95) -> CGFloat {
        let diameter = max(box.width, box.height) * boardToDoubleRing
        guard diameter > 0 else { return 1 }
        var k = fill * min(size.width, size.height) / diameter
        let cx = size.width / 2, cy = size.height / 2
        func fits(_ k: CGFloat) -> Bool {
            let half = diameter * k / 2
            let mx = (box.midX - cx) * k + cx, my = (box.midY - cy) * k + cy
            return mx - half >= 0 && mx + half <= size.width && my - half >= 0 && my + half <= size.height
        }
        while k > 1 && !fits(k) { k -= 0.02 }
        return max(1, k)
    }

    /// Kalibratie-startpunten als er geen bord gevonden is: cirkel in het midden van het beeld.
    static func defaultCalibrationGuess(imageSize size: CGSize) -> [CGPoint] {
        let r = min(size.width, size.height) * 0.3
        let box = CGRect(x: size.width / 2 - r, y: size.height / 2 - r, width: 2 * r, height: 2 * r)
        return ImageAnalysis.initialCalibrationGuess(boardBox: box)
    }
}
