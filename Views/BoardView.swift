import SwiftUI

struct BoardMarker: Identifiable, Equatable {
    let id: UUID
    /// Positie in mm (x rechts, y omhoog).
    let point: CGPoint
    let label: String
    var emphasized = false
}

extension BoardMarker {
    /// Markeringen voor de pijlen van een beurt (1, 2, 3). Handmatige worpen krijgen een representatief punt.
    static func forDarts(_ darts: [DartHit]) -> [BoardMarker] {
        darts.enumerated().compactMap { i, d in
            guard let p = d.boardPoint ?? BoardGeometry.representativePoint(for: d), !d.isMiss else { return nil }
            return BoardMarker(id: d.id, point: p, label: "\(i + 1)", emphasized: i == darts.count - 1)
        }
    }
}

/// Neutraal, strak getekend bord in de stijl van Apple Sports.
struct BoardView: View {
    var markers: [BoardMarker] = []
    var showNumbers = true

    private let dark = Color(red: 0.13, green: 0.13, blue: 0.14)
    private let light = Color(red: 0.91, green: 0.89, blue: 0.84)
    private let red = Color(red: 0.78, green: 0.22, blue: 0.24)
    private let green = Color(red: 0.18, green: 0.49, blue: 0.31)

    var body: some View {
        Canvas { ctx, size in
            let radius = Double(min(size.width, size.height)) / 2
            let cx = Double(size.width) / 2, cy = Double(size.height) / 2
            let scale: Double = radius / (BoardGeometry.doubleOutR * (showNumbers ? 1.16 : 1.02))   // punten per mm

            func pt(_ r: Double, _ deg: Double) -> CGPoint {
                let a = deg * .pi / 180
                return CGPoint(x: cx + r * scale * cos(a), y: cy - r * scale * sin(a))
            }
            func wedge(_ r1: Double, _ r2: Double, _ a1: Double, _ a2: Double) -> Path {
                var p = Path()
                let steps = 6
                p.move(to: pt(r1, a1))
                for s in 0...steps { p.addLine(to: pt(r2, a1 + (a2 - a1) * Double(s) / Double(steps))) }
                for s in stride(from: steps, through: 0, by: -1) { p.addLine(to: pt(r1, a1 + (a2 - a1) * Double(s) / Double(steps))) }
                p.closeSubpath()
                return p
            }
            func circle(_ r: Double) -> Path {
                Path(ellipseIn: CGRect(x: cx - r * scale, y: cy - r * scale, width: 2 * r * scale, height: 2 * r * scale))
            }

            // Achtergrond (nummerring)
            ctx.fill(circle(BoardGeometry.doubleOutR * (showNumbers ? 1.16 : 1.02)), with: .color(dark))

            for (i, _) in BoardGeometry.order.enumerated() {
                let a1 = 81 - Double(i) * 18, a2 = a1 + 18   // segment i ligt tussen deze hoeken
                let even = i % 2 == 0
                ctx.fill(wedge(BoardGeometry.outerBullR, BoardGeometry.trebleInR, a1, a2), with: .color(even ? dark : light))
                ctx.fill(wedge(BoardGeometry.trebleInR, BoardGeometry.trebleOutR, a1, a2), with: .color(even ? red : green))
                ctx.fill(wedge(BoardGeometry.trebleOutR, BoardGeometry.doubleInR, a1, a2), with: .color(even ? dark : light))
                ctx.fill(wedge(BoardGeometry.doubleInR, BoardGeometry.doubleOutR, a1, a2), with: .color(even ? red : green))
            }
            ctx.fill(circle(BoardGeometry.outerBullR), with: .color(green))
            ctx.fill(circle(BoardGeometry.bullR), with: .color(red))

            // Dunne "spider"
            let wire = GraphicsContext.Shading.color(.white.opacity(0.25))
            for r in [BoardGeometry.outerBullR, BoardGeometry.trebleInR, BoardGeometry.trebleOutR, BoardGeometry.doubleInR, BoardGeometry.doubleOutR] {
                ctx.stroke(circle(r), with: wire, lineWidth: 0.5)
            }

            if showNumbers {
                for (i, seg) in BoardGeometry.order.enumerated() {
                    let p = pt(BoardGeometry.doubleOutR * 1.08, 90 - Double(i) * 18)
                    ctx.draw(Text("\(seg)").font(.system(size: max(8, radius * 0.075), weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.85)), at: p)
                }
            }

            // Pijlen
            for m in markers {
                let p = CGPoint(x: cx + Double(m.point.x) * scale, y: cy - Double(m.point.y) * scale)
                let r: Double = max(7, radius * 0.055) * (m.emphasized ? 1.15 : 1)
                let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(dot, with: .color(.accentColor))
                ctx.stroke(dot, with: .color(.white), lineWidth: 2)
                ctx.draw(Text(m.label).font(.system(size: r * 1.1, weight: .bold, design: .rounded)).foregroundColor(.white), at: p)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Dartbord")
    }
}
