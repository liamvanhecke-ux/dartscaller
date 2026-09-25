import CoreImage
import CoreGraphics

/// Zet (delen van) camerabeelden om naar kleine bitmaps voor de analyse.
/// Rechthoeken zijn altijd in beeldpixels met oorsprong LINKSBOVEN (y omlaag),
/// ook al werkt Core Image intern met oorsprong linksonder.
final class FrameRenderer {

    private let context: CIContext
    /// Schrijft Core Image de onderste beeldrij als eerste weg? Eén keer gemeten i.p.v. aangenomen.
    private let bottomRowFirst: Bool

    init() {
        let ctx = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false
        ])
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 1))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        var px = [UInt8](repeating: 0, count: 16)
        ctx.render(white.composited(over: black), toBitmap: &px, rowBytes: 8,
                   bounds: CGRect(x: 0, y: 0, width: 2, height: 2), format: .RGBA8, colorSpace: nil)
        context = ctx
        bottomRowFirst = px[0] > 127   // wit staat in CI onderaan (y = 0)
    }

    /// Uitvoergrootte voor een rechthoek bij een gewenste breedte (nooit opschalen).
    static func outputSize(for rect: CGRect, targetWidth: Int) -> (width: Int, height: Int) {
        let w = max(8, min(targetWidth, Int(rect.width.rounded())))
        let h = max(8, Int((rect.height * CGFloat(w) / rect.width).rounded()))
        return (w, h)
    }

    func gray(_ image: CIImage, rect: CGRect, targetWidth: Int) -> GrayImage {
        let (w, h, rgba) = renderRGBA(image, rect: rect, targetWidth: targetWidth)
        return GrayImage(rgba: rgba, width: w, height: h)
    }

    func rgba(_ image: CIImage, rect: CGRect, targetWidth: Int) -> RGBAImage {
        let (w, h, rgba) = renderRGBA(image, rect: rect, targetWidth: targetWidth)
        return RGBAImage(width: w, height: h, pixels: rgba)
    }

    func cgImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent)
    }

    /// Uitsnede `rect` (linksboven) als CGImage, verkleind tot `targetWidth` (voor het YOLO-model).
    func cgImage(_ image: CIImage, rect: CGRect, targetWidth: Int) -> CGImage? {
        let ciRect = CGRect(x: rect.minX, y: image.extent.height - rect.maxY, width: rect.width, height: rect.height)
        let (w, h) = Self.outputSize(for: rect, targetWidth: targetWidth)
        let prepared = image
            .cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / ciRect.width, y: CGFloat(h) / ciRect.height),
                         highQualityDownsample: true)
        return context.createCGImage(prepared, from: CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func renderRGBA(_ image: CIImage, rect: CGRect, targetWidth: Int) -> (Int, Int, [UInt8]) {
        let fullHeight = image.extent.height
        // Linksboven → Core Image (linksonder)
        let ciRect = CGRect(x: rect.minX, y: fullHeight - rect.maxY, width: rect.width, height: rect.height)
        let (w, h) = Self.outputSize(for: rect, targetWidth: targetWidth)
        let sx = CGFloat(w) / ciRect.width, sy = CGFloat(h) / ciRect.height
        let prepared = image
            .cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy), highQualityDownsample: true)

        var px = [UInt8](repeating: 0, count: w * h * 4)
        context.render(prepared, toBitmap: &px, rowBytes: w * 4,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: nil)

        if bottomRowFirst {
            // Rijen omdraaien zodat rij 0 = bovenkant.
            var flipped = [UInt8](repeating: 0, count: px.count)
            let row = w * 4
            for y in 0..<h {
                let src = (h - 1 - y) * row
                flipped.replaceSubrange(y * row..<(y + 1) * row, with: px[src..<src + row])
            }
            px = flipped
        }
        return (w, h, px)
    }
}
